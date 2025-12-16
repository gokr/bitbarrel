## Compact/Compaction System for BitBarrel
##
## This module handles compaction of data files to reclaim space
## from deleted and duplicate records.

import std/[os, times, strformat, strutils, tables, options, locks, algorithm, atomics, typedthreads]
import ../bitbarrel/types, datafile, keydir, record

# Re-export types from bitbarrel/types for convenience (use qualified names to avoid os.FileInfo conflict)
export types.FileState, types.FileInfo, types.CompactStats, types.CompactConfig

type
  CompactRequest* = object
    ## A request to compact specific files
    files*: seq[types.FileInfo]
    requestTime*: Time

  CompactControllerObj* = object
    config*: types.CompactConfig
    dataDir*: string                  # Data directory for file operations
    activeFiles*: seq[types.FileInfo]
    completedFiles*: seq[types.FileInfo]
    compactInProgress*: bool
    stats*: types.CompactStats
    compactLock*: Lock
    keyDir*: KeyDir
    # Background compact support
    shutdownFlag*: Atomic[bool]       # Signal to stop background thread
    compactThread*: Thread[ptr CompactControllerObj]  # Background worker thread
    hasWorker*: bool                  # Whether background thread is running
    pendingCompact*: bool               # Whether a compact is pending
    pendingFiles*: seq[types.FileInfo]  # Files to compact in background
    compactCondition*: Cond             # Condition for signaling compact

  CompactController* = ref CompactControllerObj

  CompactPriority* = object
    score*: float
    fileInfo*: types.FileInfo
    reason*: string

# Forward declarations
proc newCompactController*(config: types.CompactConfig, keyDir: KeyDir, dataDir: string): CompactController
proc calculateCompactPriority*(controller: CompactController, file: types.FileInfo): CompactPriority
proc selectFilesForCompact*(controller: CompactController): seq[types.FileInfo]
proc performCompact*(controller: CompactController, files: seq[types.FileInfo]): bool

# Implementation

proc newCompactController*(config: types.CompactConfig, keyDir: KeyDir, dataDir: string): CompactController =
  result = CompactController()
  result.config = config
  result.keyDir = keyDir
  result.dataDir = dataDir
  result.activeFiles = @[]
  result.completedFiles = @[]
  result.compactInProgress = false
  result.stats = types.CompactStats(
    filesProcessed: 0,
    recordsScanned: 0,
    recordsKept: 0,
    recordsDropped: 0,
    bytesScanned: 0,
    bytesWritten: 0,
    timeStarted: getTime(),
    timeCompleted: getTime()
  )
  initLock(result.compactLock)
  initCond(result.compactCondition)
  result.shutdownFlag.store(false)
  result.hasWorker = false
  result.pendingCompact = false
  result.pendingFiles = @[]

proc calculateCompactPriority*(controller: CompactController, file: types.FileInfo): CompactPriority =
  ## Calculate priority score for file to determine compact order
  ## Higher score = higher priority for merging

  if not controller.config.enabled:
    return CompactPriority(score: 0.0, fileInfo: file, reason: "Compact disabled")

  var score = 0.0
  var reasons: seq[string]

  # Size-based priority: Larger files have higher priority
  score += float(file.size) / float(controller.config.maxFileSize) * 0.4

  # Fragmentation-based priority: More tombstones = higher priority
  let fragmentationRatio = if file.totalRecords > 0:
    float(file.deleteCount) / float(file.totalRecords)
  else:
    0.0

  if fragmentationRatio > controller.config.triggerThreshold:
    score += fragmentationRatio * 0.5
    reasons.add(&"Fragmentation: {fragmentationRatio:.2f}")
  else:
    score += fragmentationRatio * 0.1

  # File count consideration: Prefer merging when there are many files
  let fileCount = controller.activeFiles.len
  if fileCount >= controller.config.minFilesToCompact:
    score += float(fileCount / 10) * 0.1
    reasons.add(&"File count: {fileCount}")

  # Age consideration: Older files get higher priority
  let fileAge = getTime() - file.lastModified
  score += min(float(fileAge.inHours) / 24.0, 7.0) / 7.0 * 0.1
  reasons.add(&"Age: {fileAge.inDays}d")

  CompactPriority(score: score, fileInfo: file, reason: reasons.join(", "))

proc selectFilesForCompact*(controller: CompactController): seq[types.FileInfo] =
  ## Select files that should be compactd based on policy

  if not controller.config.enabled or controller.activeFiles.len < controller.config.minFilesToCompact:
    return @[]

  var candidates: seq[CompactPriority]

  for file in controller.activeFiles:
    if file.state == types.fsImmutable and file.deleteCount + file.duplicateCount > 0:
      let priority = calculateCompactPriority(controller, file)
      if priority.score > 0:
        candidates.add(priority)

  # Sort by priority score (highest first)
  candidates.sort(proc(a, b: CompactPriority): int = cmp(b.score, a.score))

  # Select top files to compact
  let maxFiles = min(controller.activeFiles.len, 5)  # Limit concurrent compact size
  result = @[]
  for i in 0..<min(maxFiles, candidates.len):
    result.add(candidates[i].fileInfo)

proc findDuplicates*(controller: CompactController, keyDir: var KeyDir, file: types.FileInfo): tuple[
  duplicates: int, total: int, tombstones: int, scanTime: float
] =
  ## Scan a data file to find duplicate and tombstone records
  ## Returns: (duplicate_count, total_scanned, tombstone_count, scan_duration)

  let startTime = getTime()
  var duplicates = 0
  var tombstones = 0
  var total = 0
  var filePos: uint64 = HEADER_SIZE.uint64  # Skip header

  var dataFile = datafile.open(file.path, file.id)

  try:
    while filePos < file.size:
      let (key, value, timestamp, recordSize) = dataFile.readRecordAt(filePos)
      filePos += recordSize.uint64

      inc(total)

      # Check is tombstone (empty value)
      if value.len == 0:
        inc(tombstones)
        continue

      # Check for duplicate (compare timestamps)
      let existing = keyDir.get(key)
      if existing.isSome:
        let entry = existing.get()
        if entry.timestamp < timestamp:
          inc(duplicates)
        # Count as duplicate if newer timestamp
  except IOError:
    discard  # End of file or read error
  finally:
    dataFile.close()

  let scanTime = (getTime() - startTime).inMicroseconds.float / 1_000_000

  return (duplicates, total, tombstones, scanTime)

proc performCompact*(controller: CompactController, files: seq[types.FileInfo]): bool =
  ## Perform the actual compact operation
  ## Returns true if successful, false if failed

  if files.len == 0:
    return false

  let newFileId = if files.len > 0: files[0].id + 1000 else: 1000  # Use high IDs for compactd files
  let newPath = controller.dataDir / &"{newFileId:06d}.data"
  let tempPath = newPath & ".tmp"

  controller.compactInProgress = true
  controller.stats.timeStarted = getTime()
  controller.stats.filesProcessed = files.len

  var newFileSize: uint64 = 0

  try:
    # Create new data file for compactd output
    var newDataFile = datafile.open(tempPath, newFileId)
    var fileStats = Table[string, int]()

    # Process each file
    for file in files:
      echo &"  Scanning file: {file.id} ({file.size} bytes)"
      let (duplicates, total, tombstones, scanTime) = findDuplicates(controller, controller.keyDir, file)

      controller.stats.recordsScanned += total
      controller.stats.recordsDropped += duplicates + tombstones
      controller.stats.bytesScanned += file.size.int64

      fileStats["duplicates"] = fileStats.getOrDefault("duplicates", 0) + duplicates
      fileStats["tombstones"] = fileStats.getOrDefault("tombstones", 0) + tombstones
      fileStats["total"] = fileStats.getOrDefault("total", 0) + total

      # Scan and copy live records to new file
      var oldDataFile = datafile.open(file.path, file.id)
      var filePos: uint64 = HEADER_SIZE.uint64  # Skip header

      try:
        while filePos < file.size:
          let (key, value, timestamp, recordSize) = oldDataFile.readRecordAt(filePos)
          filePos += recordSize.uint64

          # Skip tombstones
          if value.len == 0:
            continue

          # Skip expired records
          if isExpired(timestamp):
            controller.stats.recordsDropped += 1
            continue

          # Check for duplicate using latest timestamp
          let existing = controller.keyDir.get(key)
          if existing.isSome:
            let entry = existing.get()
            let isDuplicate = entry.timestamp > timestamp

            if not isDuplicate:
              # Write the record to new file
              let newPos = newDataFile.appendRecord(key, value, timestamp)
              controller.keyDir.add(key, KeyDirEntry(
                fileId: newFileId,
                recordPos: newPos.recordPos,
                valuePos: newPos.valuePos,
                valueSize: newPos.valueSize,
                timestamp: timestamp,
                recordSize: newPos.recordSize
              ))
              controller.stats.recordsKept += 1
              controller.stats.bytesWritten += recordSize.int64

      except IOError:
        discard  # End of file or read error

      finally:
        oldDataFile.close()

    # Capture size before closing
    newFileSize = newDataFile.size
    newDataFile.close()

    # Atomic rename operations
    moveFile(tempPath, newPath)

    # Add new file to completed list
    let newFileInfo = types.FileInfo(
      path: newPath,
      id: newFileId,
      size: newFileSize,
      state: types.fsActive,
      created: getTime(),
      lastModified: getTime(),
      deleteCount: 0,
      totalRecords: controller.stats.recordsKept,
      duplicateCount: 0,
      liveRecords: controller.stats.recordsKept
    )

    controller.completedFiles.add(newFileInfo)

    # Remove deleted files from active list
    for file in files:
      var idx = -1
      for i, f in controller.activeFiles:
        if f.id == file.id:
          idx = i
          break
      if idx >= 0:
        controller.activeFiles.delete(idx)

    controller.activeFiles.add(newFileInfo)

    # Delete old files
    for file in files:
      if fileExists(file.path):
        removeFile(file.path)

  except Exception as e:
    echo &"Error during compact: {e.msg}"
    # Clean up temp file if it exists
    if fileExists(tempPath):
      removeFile(tempPath)
    controller.compactInProgress = false
    return false

  controller.compactInProgress = false
  controller.stats.timeCompleted = getTime()

  echo &"Compact completed successfully!"
  echo &"   Records kept: {controller.stats.recordsKept}"
  echo &"   Records dropped: {controller.stats.recordsDropped}"
  echo &"   Files processed: {controller.stats.filesProcessed}"
  echo &"   Time: {(getTime() - controller.stats.timeStarted).inSeconds} seconds"

  return true

proc triggerCompact*(controller: CompactController) =
  ## Trigger a manual compact operation
  withLock(controller.compactLock):
    if controller.activeFiles.len >= controller.config.minFilesToCompact:
      let filesToCompact = selectFilesForCompact(controller)
      if filesToCompact.len > 0:
        discard performCompact(controller, filesToCompact)

proc getCompactStats*(controller: CompactController): types.CompactStats =
  ## Get current compact statistics
  ## Returns a copy to avoid race conditions
  withLock(controller.compactLock):
    result = controller.stats

# Background compact worker functions

proc compactWorker*(controllerPtr: ptr CompactControllerObj) {.thread.} =
  ## Background worker thread for compact operations
  let controller = cast[CompactController](controllerPtr)

  while not controller.shutdownFlag.load():
    var filesToCompact: seq[types.FileInfo] = @[]

    withLock(controller.compactLock):
      if controller.shutdownFlag.load():
        break

      # Wait for compact signal
      if not controller.pendingCompact:
        controller.compactCondition.wait(controller.compactLock)

      # Check again after waking
      if controller.shutdownFlag.load():
        break

      if controller.pendingCompact:
        filesToCompact = controller.pendingFiles
        controller.pendingCompact = false
        controller.pendingFiles = @[]

    # Perform compact outside lock
    if filesToCompact.len > 0:
      discard performCompact(controller, filesToCompact)

proc startCompactWorker*(controller: CompactController) =
  ## Start the background compact worker thread
  if not controller.hasWorker:
    controller.shutdownFlag.store(false)
    createThread(controller.compactThread, compactWorker, addr controller[])
    controller.hasWorker = true

proc stopCompactWorker*(controller: CompactController) =
  ## Stop the background compact worker thread and wait for it to finish
  if controller.hasWorker:
    withLock(controller.compactLock):
      controller.shutdownFlag.store(true)
      controller.compactCondition.signal()
    joinThread(controller.compactThread)
    controller.hasWorker = false

proc queueCompact*(controller: CompactController, files: seq[types.FileInfo]) =
  ## Queue files for background compact (non-blocking)
  withLock(controller.compactLock):
    if not controller.pendingCompact and files.len > 0:
      controller.pendingFiles = files
      controller.pendingCompact = true
      controller.compactCondition.signal()

proc triggerBackgroundCompact*(controller: CompactController) =
  ## Trigger a background compact operation (non-blocking)
  ## Selects files automatically and queues them for compact
  withLock(controller.compactLock):
    if not controller.pendingCompact and not controller.compactInProgress:
      if controller.activeFiles.len >= controller.config.minFilesToCompact:
        let filesToCompact = selectFilesForCompact(controller)
        if filesToCompact.len > 0:
          controller.pendingFiles = filesToCompact
          controller.pendingCompact = true
          controller.compactCondition.signal()

proc isCompactPending*(controller: CompactController): bool =
  ## Check if a compact is currently pending
  withLock(controller.compactLock):
    result = controller.pendingCompact

proc shutdown*(controller: CompactController) =
  ## Clean shutdown - stop worker and clean up resources
  controller.stopCompactWorker()
  deinitLock(controller.compactLock)
  deinitCond(controller.compactCondition)