## Compact System for BitBarrel
##
## This module handles compaction of a single data file to reclaim space
## from deleted and expired records.

import std/[os, times, strformat, strutils, locks, atomics, typedthreads]
import ../bitbarrel/types, datafile, keydir, record, critbitindex

type
  # Callback type for updating index entries after compaction
  IndexUpdateProc* = proc(key: string, entry: KeyDirEntry) {.gcsafe.}

  CompactControllerObj* = object
    config*: types.CompactConfig
    updateEntry*: IndexUpdateProc     # Callback to update index (KeyDir or CritBit)
    # Auto-compaction support
    barrelPath*: string               # Store data directory path
    currentFileId*: uint32            # Track current file ID
    # Background compact support
    shutdownFlag*: Atomic[bool]       # Signal to stop background thread
    compactThread*: Thread[ptr CompactControllerObj]  # Background worker thread
    hasWorker*: bool                  # Whether background thread is running
    pendingCompact*: bool               # Whether a compact is pending
    compactCondition*: Cond             # Condition for signaling compact
    compactInProgress*: bool           # Whether a compact is currently running
    compactLock*: Lock                 # Lock for thread safety
    stats*: types.CompactStats          # Statistics for the last compact

  CompactController* = ref CompactControllerObj

proc `=destroy`*(controller: var CompactControllerObj) =
  ## Destructor for CompactController
  ## Properly clean up locks and condition variables
  ## This is called by ORC when the object is being garbage collected
  if controller.hasWorker:
    # Signal shutdown to worker thread
    controller.shutdownFlag.store(true)
    withLock(controller.compactLock):
      controller.compactCondition.signal()
    # Don't join here - it can cause deadlocks during GC
    controller.hasWorker = false

  # Deinitialize lock and condition variable
  # These are designed to be safe to call multiple times
  deinitLock(controller.compactLock)
  deinitCond(controller.compactCondition)

# Forward declarations
proc newCompactController*(config: types.CompactConfig, updateEntry: IndexUpdateProc): CompactController
proc newCompactController*(config: types.CompactConfig): CompactController
proc newCompactController*(config: types.CompactConfig, keyDir: var KeyDir): CompactController
proc newCompactController*(config: types.CompactConfig, critBit: var CritBitIndex): CompactController
proc performCompact*(controller: CompactController, dataPath: string, fileId: uint32): bool

# Implementation

proc newCompactController*(config: types.CompactConfig, updateEntry: IndexUpdateProc): CompactController =
  ## Create a new compact controller with callback for index updates
  result = CompactController()
  result.config = config
  result.updateEntry = updateEntry
  result.barrelPath = ""  # Will be set later
  result.currentFileId = 0'u32  # Will be updated by worker
  result.shutdownFlag.store(false)
  result.hasWorker = false
  result.pendingCompact = false
  result.compactInProgress = false
  initLock(result.compactLock)
  initCond(result.compactCondition)
  result.stats = types.CompactStats(
    recordsScanned: 0,
    recordsKept: 0,
    recordsDropped: 0,
    bytesScanned: 0,
    bytesWritten: 0,
    timeStarted: getTime(),
    timeCompleted: getTime()
  )

proc newCompactController*(config: types.CompactConfig): CompactController =
  ## Create a new compact controller with no index update callback
  ## Used for ranged modes where index updates are handled separately
  result = newCompactController(config, nil)

proc newCompactController*(config: types.CompactConfig, keyDir: ptr KeyDir): CompactController =
  ## Create a new compact controller for KeyDir (backward compatible)
  ## Creates a callback that updates the KeyDir
  proc updateCallback(key: string, entry: KeyDirEntry) {.gcsafe.} =
    keyDir[].add(key, entry)
  result = newCompactController(config, updateCallback)

proc newCompactController*(config: types.CompactConfig, keyDir: var KeyDir): CompactController =
  ## Create a new compact controller for KeyDir (backward compatible)
  result = newCompactController(config, addr(keyDir))

proc newCompactController*(config: types.CompactConfig, critBit: ptr CritBitIndex): CompactController =
  ## Create a new compact controller for CritBit index
  ## Creates a callback that updates the CritBit index
  proc updateCallback(key: string, entry: KeyDirEntry) {.gcsafe.} =
    critBit[].add(key, entry)
  result = newCompactController(config, updateCallback)

proc newCompactController*(config: types.CompactConfig, critBit: var CritBitIndex): CompactController =
  ## Create a new compact controller for CritBit index
  result = newCompactController(config, addr(critBit))

proc calculateFragmentation*(dataPath: string, validateCrc: bool = false): tuple[live: int, total: int, ratio: float] =
  ## Calculate fragmentation ratio of a data file
  ## Returns: (live_records, total_records, fragmentation_ratio)
  ## validateCrc: if false, CRC validation is skipped (for debugging corrupted files)

  var dataFile = datafile.open(dataPath, 0'u32, syncImmediate, true, 0, validateCrc)  # File ID doesn't matter for reading
  defer: dataFile.close()

  var total = 0
  var live = 0
  var filePos: uint64 = HEADER_SIZE.uint64  # Skip header

  try:
    while filePos < dataFile.size:
      let (_, value, timestamp, recordSize) = dataFile.readRecordAt(filePos)
      filePos += recordSize.uint64
      inc(total)

      # Check if tombstone (empty value)
      if value.len > 0 and not isExpired(timestamp):
        inc(live)
  except IOError, ValueError:
    # End of file or read error - this is expected when we reach EOF
    discard

  let ratio = if total > 0: (float(total - live) / float(total)) else: 0.0
  (live: live, total: total, ratio: ratio)

proc setBarrelPath*(controller: CompactController, path: string) =
  ## Set the barrel data path for auto-compaction
  controller.barrelPath = path

proc getCurrentFileId*(dataPath: string): uint32 =
  ## Get the current (highest) file ID in the data directory
  ## Assumes files are named like: data/000001.data, data/000002.data, etc.
  var maxId: uint32 = 0

  try:
    for kind, path in walkDir(dataPath):
      if kind == pcFile and path.endsWith(".data"):
        let filename = path.extractFilename()
        # Extract ID from filename like "000001.data"
        let idStr = filename.split('.')[0]
        if idStr.len == 6:
          try:
            let id = parseUInt(idStr).uint32
            if id > maxId:
              maxId = id
          except CatchableError:
            discard
  except CatchableError:
    discard

  maxId

proc performCompact*(controller: CompactController, dataPath: string, fileId: uint32): bool =
  ## Perform compaction on a single data file
  ## Reads the current file, filters out dead records, writes to new file
  ## Returns true if successful, false if failed

  if not controller.config.enabled:
    return false

  # Calculate fragmentation to see if compaction is needed
  let (_, _, fragmentation) = calculateFragmentation(dataPath, validateCrc=false)
  let fileSize = getFileSize(dataPath).uint64

  if fragmentation < controller.config.triggerThreshold and fileSize < controller.config.maxFileSize:
    echo &"Skipping compaction: fragmentation {fragmentation:.2f} < threshold {controller.config.triggerThreshold}"
    return false

  echo &"Starting compaction: file={fileId}, size={fileSize}, fragmentation={fragmentation:.2f}"

  controller.compactInProgress = true
  controller.stats.timeStarted = getTime()
  controller.stats.recordsScanned = 0
  controller.stats.recordsKept = 0
  controller.stats.recordsDropped = 0
  controller.stats.bytesScanned = fileSize.int64
  controller.stats.bytesWritten = 0

  let newFileId = fileId + 1  # Use next ID for compacted file

  # Calculate new path - handle both numbered (000001.data) and simple (test.data) filenames
  var newPath: string
  if dataPath.contains(".data"):
    let extIdx = dataPath.rfind(".")
    if extIdx > 0 and dataPath.len >= 6:
      # Extract just the filename, not the full path
      let filename = dataPath.extractFilename()
      let fileExtIdx = filename.rfind(".")
      let namePart = if fileExtIdx > 0: filename[0 ..< fileExtIdx] else: filename

      # Check if it's a numbered file like "000001.data"
      let allDigits = namePart.len == 6 and namePart.allCharsInSet({'0'..'9'})
      if allDigits:
        # Replace numbered file - construct new filename with padding
        let paddedId = $newFileId
        let numStr = repeat("0", 6 - paddedId.len) & paddedId
        newPath = dataPath.replace(&"{fileId:06d}.data", numStr & ".data")
      else:
        # Simple filename like "test.data" -> "test_000002.data"
        let paddedId = $newFileId
        let suffix = repeat("0", 6 - paddedId.len) & paddedId
        newPath = dataPath.replace(".data", &"_{suffix}.data")
    else:
      # Fallback
      let paddedId = $newFileId
      let suffix = repeat("0", 6 - paddedId.len) & paddedId
      newPath = dataPath & &"_{suffix}"
  else:
    # No extension
    let paddedId = $newFileId
    let suffix = repeat("0", 6 - paddedId.len) & paddedId
    newPath = dataPath & &"_{suffix}"

  let tempPath = newPath & ".tmp"

  var newFileSize: uint64 = 0

  try:
    # Open the original file for reading
    var originalFile = datafile.open(dataPath, fileId)
    defer: originalFile.close()

    # Create new data file for compacted output
    var newDataFile = datafile.open(tempPath, newFileId)

    # Scan and copy live records to new file
    var filePos: uint64 = HEADER_SIZE.uint64  # Skip header

    try:
      while filePos < originalFile.size:
        let (key, value, timestamp, recordSize) = originalFile.readRecordAt(filePos)
        filePos += recordSize.uint64
        inc(controller.stats.recordsScanned)

        # Skip tombstones
        if value.len == 0:
          inc(controller.stats.recordsDropped)
          continue

        # Skip expired records
        if isExpired(timestamp):
          inc(controller.stats.recordsDropped)
          continue

        # Write the record to new file
        let newPos = newDataFile.appendRecord(key, value, timestamp)
        controller.stats.bytesWritten += recordSize.int64

        # Update index with new position using callback
        if controller.updateEntry != nil:
          controller.updateEntry(key, KeyDirEntry(
            fileId: newFileId,
            recordPos: newPos.recordPos,
            valuePos: newPos.valuePos,
            valueSize: newPos.valueSize,
            timestamp: timestamp,
            recordSize: newPos.recordSize,
            deleted: false  # Non-tombstone records only reach here
          ))
        inc(controller.stats.recordsKept)

    except IOError:
      discard  # End of file or read error

    # Capture size before closing
    newFileSize = newDataFile.size
    newDataFile.close()

    # Atomic rename operation
    moveFile(tempPath, newPath)

    # Delete old file
    if fileExists(dataPath):
      removeFile(dataPath)

    # Return info about the new file
    echo &"Compaction completed successfully!"
    echo &"   Records kept: {controller.stats.recordsKept}"
    echo &"   Records dropped: {controller.stats.recordsDropped}"
    echo &"   Old size: {fileSize}"
    echo &"   New size: {newFileSize}"
    echo &"   Space saved: {fileSize - newFileSize} bytes"
    echo &"   Time: {(getTime() - controller.stats.timeStarted).inSeconds} seconds"

    controller.stats.timeCompleted = getTime()
    controller.compactInProgress = false
    return true

  except Exception as e:
    echo &"Error during compaction: {e.msg}"
    # Clean up temp file if it exists
    if fileExists(tempPath):
      removeFile(tempPath)
    controller.compactInProgress = false
    return false

proc triggerCompact*(controller: CompactController, dataPath: string, fileId: uint32) =
  ## Trigger a manual compaction operation
  withLock(controller.compactLock):
    if not controller.compactInProgress:
      discard performCompact(controller, dataPath, fileId)

proc getCompactStats*(controller: CompactController): types.CompactStats =
  ## Get current compaction statistics
  ## Returns a copy to avoid race conditions
  withLock(controller.compactLock):
    result = controller.stats

# Background compact worker functions

proc compactWorker*(controllerPtr: ptr CompactControllerObj) {.thread.} =
  ## Background worker thread for compact operations
  ## Wakes periodically to check for auto-compact conditions
  let controller = cast[CompactController](controllerPtr)
  let checkIntervalMs = controller.config.compactInterval * 1000  # seconds to ms

  while not controller.shutdownFlag.load():
    # Sleep for the check interval (allows shutdown checks)
    var sleptMs = 0
    while sleptMs < checkIntervalMs and not controller.shutdownFlag.load():
      sleep(100)  # Check shutdown every 100ms
      sleptMs += 100

    if controller.shutdownFlag.load():
      break

    # Skip if no barrel path set
    if controller.barrelPath.len == 0:
      continue

    # Check if we need to compact current file
    let currentFile = getCurrentFileId(controller.barrelPath)

    # Initialize currentFileId on first run
    if controller.currentFileId == 0:
      controller.currentFileId = currentFile

    # Check if it's a new file or if we should check the current file
    if currentFile != controller.currentFileId or currentFile == controller.currentFileId:
      controller.currentFileId = currentFile

      # Build the actual data file path
      let dataFilePath = joinPath(controller.barrelPath, &"{currentFile:06d}.data")

      # Check if file exists before trying to calculate fragmentation
      if fileExists(dataFilePath):
        # Check fragmentation
        let (_, _, fragmentation) = calculateFragmentation(dataFilePath)

        # Trigger compaction if fragmentation exceeds threshold
        if fragmentation > controller.config.triggerThreshold:
          withLock(controller.compactLock):
            if not controller.compactInProgress:
              echo &"Auto-compaction triggered: fragmentation {fragmentation:.2f} > threshold {controller.config.triggerThreshold}"
              # Note: This will make the file, but the barrel needs to be notified to reopen it
              # For now, we just perform the compaction
              discard performCompact(controller, dataFilePath, currentFile)

    # Handle explicit pending compact requests
    withLock(controller.compactLock):
      if controller.pendingCompact:
        controller.pendingCompact = false
        # For manual triggers, compact the current file
        if controller.barrelPath.len > 0:
          let currentFile = getCurrentFileId(controller.barrelPath)
          let dataFilePath = joinPath(controller.barrelPath, &"{currentFile:06d}.data")
          if fileExists(dataFilePath):
            discard performCompact(controller, dataFilePath, currentFile)

proc startCompactWorker*(controller: CompactController) =
  ## Start the background compact worker thread
  if not controller.hasWorker and controller.config.enabled:
    controller.shutdownFlag.store(false)
    controller.compactThread.createThread(compactWorker, cast[ptr CompactControllerObj](controller))
    controller.hasWorker = true

proc stopCompactWorker*(controller: CompactController) =
  ## Stop the background compact worker thread
  if controller.hasWorker:
    controller.shutdownFlag.store(true)
    withLock(controller.compactLock):
      controller.compactCondition.signal()
    controller.compactThread.joinThread()
    controller.hasWorker = false

proc isCompactInProgress*(controller: CompactController): bool =
  ## Check if a compact is currently in progress
  withLock(controller.compactLock):
    result = controller.compactInProgress

proc shutdown*(controller: CompactController) =
  ## Clean shutdown - stop worker and clean up resources
  if controller != nil:
    controller.stopCompactWorker()
    deinitLock(controller.compactLock)
    deinitCond(controller.compactCondition)