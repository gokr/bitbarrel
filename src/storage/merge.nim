## Merge/Compaction System for Bitcask KVS
##
## This module handles compaction of data files to reclaim space
## from deleted and duplicate records.

import std/[os, times, strformat, strutils, tables, options, locks, algorithm, atomics, typedthreads]
import ../bitbarrel/types, datafile, keydir

# Re-export types from bitbarrel/types for convenience (use qualified names to avoid os.FileInfo conflict)
export types.FileState, types.FileInfo, types.MergeStats, types.MergeConfig

type
  MergeRequest* = object
    ## A request to merge specific files
    files*: seq[types.FileInfo]
    requestTime*: Time

  MergeControllerObj* = object
    config*: types.MergeConfig
    dataDir*: string                  # Data directory for file operations
    activeFiles*: seq[types.FileInfo]
    completedFiles*: seq[types.FileInfo]
    mergeInProgress*: bool
    stats*: types.MergeStats
    mergeLock*: Lock
    keyDir*: KeyDir
    # Background merge support
    shutdownFlag*: Atomic[bool]       # Signal to stop background thread
    mergeThread*: Thread[ptr MergeControllerObj]  # Background worker thread
    hasWorker*: bool                  # Whether background thread is running
    pendingMerge*: bool               # Whether a merge is pending
    pendingFiles*: seq[types.FileInfo]  # Files to merge in background
    mergeCondition*: Cond             # Condition for signaling merge

  MergeController* = ref MergeControllerObj

  MergePriority* = object
    score*: float
    fileInfo*: types.FileInfo
    reason*: string

# Forward declarations
proc newMergeController*(config: types.MergeConfig, keyDir: KeyDir, dataDir: string): MergeController
proc calculateMergePriority*(controller: MergeController, file: types.FileInfo): MergePriority
proc selectFilesForMerge*(controller: MergeController): seq[types.FileInfo]
proc performMerge*(controller: MergeController, files: seq[types.FileInfo]): bool

# Implementation

proc newMergeController*(config: types.MergeConfig, keyDir: KeyDir, dataDir: string): MergeController =
  result = MergeController()
  result.config = config
  result.keyDir = keyDir
  result.dataDir = dataDir
  result.activeFiles = @[]
  result.completedFiles = @[]
  result.mergeInProgress = false
  result.stats = types.MergeStats(
    filesProcessed: 0,
    recordsScanned: 0,
    recordsKept: 0,
    recordsDropped: 0,
    bytesScanned: 0,
    bytesWritten: 0,
    timeStarted: getTime(),
    timeCompleted: getTime()
  )
  initLock(result.mergeLock)
  initCond(result.mergeCondition)
  result.shutdownFlag.store(false)
  result.hasWorker = false
  result.pendingMerge = false
  result.pendingFiles = @[]

proc calculateMergePriority*(controller: MergeController, file: types.FileInfo): MergePriority =
  ## Calculate priority score for file to determine merge order
  ## Higher score = higher priority for merging

  if not controller.config.enabled:
    return MergePriority(score: 0.0, fileInfo: file, reason: "Merge disabled")

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
  if fileCount >= controller.config.minFilesToMerge:
    score += float(fileCount / 10) * 0.1
    reasons.add(&"File count: {fileCount}")

  # Age consideration: Older files get higher priority
  let fileAge = getTime() - file.lastModified
  score += min(float(fileAge.inHours) / 24.0, 7.0) / 7.0 * 0.1
  reasons.add(&"Age: {fileAge.inDays}d")

  MergePriority(score: score, fileInfo: file, reason: reasons.join(", "))

proc selectFilesForMerge*(controller: MergeController): seq[types.FileInfo] =
  ## Select files that should be merged based on policy

  if not controller.config.enabled or controller.activeFiles.len < controller.config.minFilesToMerge:
    return @[]

  var candidates: seq[MergePriority]

  for file in controller.activeFiles:
    if file.state == types.fsImmutable and file.deleteCount + file.duplicateCount > 0:
      let priority = calculateMergePriority(controller, file)
      if priority.score > 0:
        candidates.add(priority)

  # Sort by priority score (highest first)
  candidates.sort(proc(a, b: MergePriority): int = cmp(b.score, a.score))

  # Select top files to merge
  let maxFiles = min(controller.activeFiles.len, 5)  # Limit concurrent merge size
  result = @[]
  for i in 0..<min(maxFiles, candidates.len):
    result.add(candidates[i].fileInfo)

proc findDuplicates*(controller: MergeController, keyDir: var KeyDir, file: types.FileInfo): tuple[
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

proc performMerge*(controller: MergeController, files: seq[types.FileInfo]): bool =
  ## Perform the actual merge operation
  ## Returns true if successful, false if failed

  if files.len == 0:
    return false

  let newFileId = if files.len > 0: files[0].id + 1000 else: 1000  # Use high IDs for merged files
  let newPath = controller.dataDir / &"{newFileId:06d}.data"
  let tempPath = newPath & ".tmp"

  controller.mergeInProgress = true
  controller.stats.timeStarted = getTime()
  controller.stats.filesProcessed = files.len

  var newFileSize: uint64 = 0

  try:
    # Create new data file for merged output
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
    echo &"Error during merge: {e.msg}"
    # Clean up temp file if it exists
    if fileExists(tempPath):
      removeFile(tempPath)
    controller.mergeInProgress = false
    return false

  controller.mergeInProgress = false
  controller.stats.timeCompleted = getTime()

  echo &"Merge completed successfully!"
  echo &"   Records kept: {controller.stats.recordsKept}"
  echo &"   Records dropped: {controller.stats.recordsDropped}"
  echo &"   Files processed: {controller.stats.filesProcessed}"
  echo &"   Time: {(getTime() - controller.stats.timeStarted).inSeconds} seconds"

  return true

proc triggerMerge*(controller: MergeController) =
  ## Trigger a manual merge operation
  withLock(controller.mergeLock):
    if controller.activeFiles.len >= controller.config.minFilesToMerge:
      let filesToMerge = selectFilesForMerge(controller)
      if filesToMerge.len > 0:
        discard performMerge(controller, filesToMerge)

proc getMergeStats*(controller: MergeController): types.MergeStats =
  ## Get current merge statistics
  ## Returns a copy to avoid race conditions
  withLock(controller.mergeLock):
    result = controller.stats

# Background merge worker functions

proc mergeWorker*(controllerPtr: ptr MergeControllerObj) {.thread.} =
  ## Background worker thread for merge operations
  let controller = cast[MergeController](controllerPtr)

  while not controller.shutdownFlag.load():
    var filesToMerge: seq[types.FileInfo] = @[]

    withLock(controller.mergeLock):
      if controller.shutdownFlag.load():
        break

      # Wait for merge signal
      if not controller.pendingMerge:
        controller.mergeCondition.wait(controller.mergeLock)

      # Check again after waking
      if controller.shutdownFlag.load():
        break

      if controller.pendingMerge:
        filesToMerge = controller.pendingFiles
        controller.pendingMerge = false
        controller.pendingFiles = @[]

    # Perform merge outside lock
    if filesToMerge.len > 0:
      discard performMerge(controller, filesToMerge)

proc startMergeWorker*(controller: MergeController) =
  ## Start the background merge worker thread
  if not controller.hasWorker:
    controller.shutdownFlag.store(false)
    createThread(controller.mergeThread, mergeWorker, addr controller[])
    controller.hasWorker = true

proc stopMergeWorker*(controller: MergeController) =
  ## Stop the background merge worker thread and wait for it to finish
  if controller.hasWorker:
    withLock(controller.mergeLock):
      controller.shutdownFlag.store(true)
      controller.mergeCondition.signal()
    joinThread(controller.mergeThread)
    controller.hasWorker = false

proc queueMerge*(controller: MergeController, files: seq[types.FileInfo]) =
  ## Queue files for background merge (non-blocking)
  withLock(controller.mergeLock):
    if not controller.pendingMerge and files.len > 0:
      controller.pendingFiles = files
      controller.pendingMerge = true
      controller.mergeCondition.signal()

proc triggerBackgroundMerge*(controller: MergeController) =
  ## Trigger a background merge operation (non-blocking)
  ## Selects files automatically and queues them for merge
  withLock(controller.mergeLock):
    if not controller.pendingMerge and not controller.mergeInProgress:
      if controller.activeFiles.len >= controller.config.minFilesToMerge:
        let filesToMerge = selectFilesForMerge(controller)
        if filesToMerge.len > 0:
          controller.pendingFiles = filesToMerge
          controller.pendingMerge = true
          controller.mergeCondition.signal()

proc isMergePending*(controller: MergeController): bool =
  ## Check if a merge is currently pending
  withLock(controller.mergeLock):
    result = controller.pendingMerge

proc shutdown*(controller: MergeController) =
  ## Clean shutdown - stop worker and clean up resources
  controller.stopMergeWorker()
  deinitLock(controller.mergeLock)
  deinitCond(controller.mergeCondition)