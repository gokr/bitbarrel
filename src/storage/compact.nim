## Compact System for BitBarrel
##
## This module handles compaction of a single data file to reclaim space
## from deleted and expired records.

import std/[os, times, strformat, strutils, locks, atomics, typedthreads]
import ../bitbarrel/types, datafile, keydir, record

type
  CompactControllerObj* = object
    config*: types.CompactConfig
    keyDir*: KeyDir
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

# Forward declarations
proc newCompactController*(config: types.CompactConfig, keyDir: KeyDir): CompactController
proc performCompact*(controller: CompactController, dataPath: string, fileId: uint32): bool

# Implementation

proc newCompactController*(config: types.CompactConfig, keyDir: KeyDir): CompactController =
  ## Create a new compact controller
  result = CompactController()
  result.config = config
  result.keyDir = keyDir
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

proc calculateFragmentation*(dataPath: string): tuple[live: int, total: int, ratio: float] =
  ## Calculate fragmentation ratio of a data file
  ## Returns: (live_records, total_records, fragmentation_ratio)

  var dataFile = datafile.open(dataPath, 0'u32)  # File ID doesn't matter for reading
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
  except IOError:
    discard  # End of file or read error

  let ratio = if total > 0: (float(total - live) / float(total)) else: 0.0
  (live: live, total: total, ratio: ratio)

proc performCompact*(controller: CompactController, dataPath: string, fileId: uint32): bool =
  ## Perform compaction on a single data file
  ## Reads the current file, filters out dead records, writes to new file
  ## Returns true if successful, false if failed

  if not controller.config.enabled:
    return false

  # Calculate fragmentation to see if compaction is needed
  let (_, _, fragmentation) = calculateFragmentation(dataPath)
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
  let newPath = dataPath.replace(&"{fileId:06d}.data", &"{newFileId:06d}.data")
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

        # Update KeyDir with new position
        controller.keyDir.add(key, KeyDirEntry(
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

    finally:
      newDataFile.close()

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

    # Check for pending compact or auto-compact trigger
    withLock(controller.compactLock):
      if controller.compactInProgress:
        continue  # Already running, skip this cycle

      # Handle explicit pending compact requests
      if controller.pendingCompact:
        controller.pendingCompact = false
        # Note: In single-file mode, compact needs to be triggered with actual data file info
        # The caller should use performCompact directly with the file path
        continue

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