## Merge/Compaction System for Bitcask KVS
##
## This module handles compaction of data files to reclaim space
## from deleted and duplicate records.

import std/[os, times, strformat, strutils, tables, options, locks, algorithm]
import ../kvs/types, datafile, keydir

type
  FileState* = enum
    fsActive     # Currently writable
    fsImmutable   # Read-only, candidate for merge
    fsMerging    # Currently being merged
    fsDeleted    # Marked for deletion

  FileInfo* = object
    path*: string               # Full path to file
    id*: uint32                # File ID
    size*: uint64                # Current file size
    state*: FileState            # Current state
    created*: Time               # Creation timestamp
    lastModified*: Time           # Last modification
    deleteCount*: int            # Number of deleted/tombstone records
    totalRecords*: int           # Total records in file
    duplicateCount*: int         # Superseded records
    liveRecords*: int            # Active (non-deleted) records

  MergeStats* = object
    filesProcessed*: int
    recordsScanned*: int
    recordsKept*: int
    recordsDropped*: int
    bytesScanned*: int64
    bytesWritten*: int64
    timeStarted*: Time
    timeCompleted*: Time

  MergeConfig* = ref object
    enabled*: bool
    maxFileSize*: uint64
    minFilesToMerge*: int
    triggerThreshold*: float
    maxMergeThreads*: int
    mergeInterval*: int
    mergeIntervalBytes*: int64
    skipThreshold*: int

  MergeController* = ref object
    config*: MergeConfig
    activeFiles*: seq[FileInfo]
    completedFiles*: seq[FileInfo]
    mergeInProgress*: bool
    stats*: MergeStats
    mergeLock*: Lock
    keyDir*: KeyDir

  MergePriority* = object
    score*: float
    fileInfo*: FileInfo
    reason*: string

# Forward declarations
proc newMergeController*(config: MergeConfig, keyDir: KeyDir): MergeController
proc calculateMergePriority*(controller: MergeController, file: FileInfo): MergePriority
proc selectFilesForMerge*(controller: MergeController): seq[FileInfo]
proc performMerge*(controller: MergeController, files: seq[FileInfo]): bool

# Implementation

proc newMergeController*(config: MergeConfig, keyDir: KeyDir): MergeController =
  result = MergeController()
  result.config = config
  result.keyDir = keyDir
  result.activeFiles = @[]
  result.completedFiles = @[]
  result.mergeInProgress = false
  result.stats = MergeStats(
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

proc calculateMergePriority*(controller: MergeController, file: FileInfo): MergePriority =
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

proc selectFilesForMerge*(controller: MergeController): seq[FileInfo] =
  ## Select files that should be merged based on policy

  if not controller.config.enabled or controller.activeFiles.len < controller.config.minFilesToMerge:
    return @[]

  var candidates: seq[MergePriority]

  for file in controller.activeFiles:
    if file.state == fsImmutable and file.deleteCount + file.duplicateCount > 0:
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

proc findDuplicates*(controller: MergeController, keyDir: KeyDir, file: FileInfo): tuple[
  duplicates: int, total: int, tombstones: int, scanTime: float
] =
  ## Scan a data file to find duplicate and tombstone records
  ## Returns: (duplicate_count, total_scanned, tombstone_count, scan_duration)

  let startTime = getTime()
  var duplicates = 0
  var tombstones = 0
  var total = 0
  var filePos: uint64 = 32  # Skip header

  let dataFile = datafile.open(file.path, file.id)

  try:
    while filePos < file.size:
      let (key, value, timestamp, recordSize) = dataFile.readRecord(filePos)
      filePos += recordSize

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

proc performMerge*(controller: MergeController, files: seq[FileInfo]): bool =
  ## Perform the actual merge operation
  ## Returns true if successful, false if failed

  if files.len == 0:
    return false

  let newFileId = if files.len > 0: files[0].id + 1 else: 1
  let dataDir = ""  # Would get from config eventually
  let newPath = &"{dataDir}/{newFileId:06d}.data"
  let tempPath = newPath & ".tmp"

  controller.mergeInProgress = true
  controller.stats.timeStarted = getTime()
  controller.stats.filesProcessed = files.len

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
      controller.stats.bytesScanned += file.size

      fileStats["duplicates"] = fileStats.getOrDefault("duplicates", 0) + duplicates
      fileStats["tombstones"] = fileStats.getOrDefault("tombstones", 0) + tombstones
      fileStats["total"] = fileStats.getOrDefault("total", 0) + total

      # Scan and copy live records to new file
      let oldDataFile = datafile.open(file.path, file.id)
      var filePos: uint64 = 32  # Skip header

      try:
        while filePos < file.size:
          let (key, value, timestamp, recordSize) = dataFile.readRecord(filePos)
          filePos += recordSize

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
              controller.stats.bytesWritten += recordSize

      except EOF:
        break

      finally:
        oldDataFile.close()

        # Update file stats
        file.merge(fileStats)
        file.state = fsDeleted

    finally:
      newDataFile.close()

    # Atomic rename operations
    moveFile(tempPath, newPath)

    # Update file status
    for file in files:
      file.state = fsDeleted

    # Add new file to completed list
    let newFileInfo = FileInfo(
      path: newPath,
      id: newFileId,
      size: newDataFile.size,
      state: fsActive,
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
      let idx = controller.activeFiles.find(proc(f: FileInfo): f.id == file.id)
      if idx >= 0:
        controller.activeFiles.delete(idx)

    controller.activeFiles.add(newFileInfo)

  except Exception as e:
    echo &"Error during merge: {e.msg}"
    # Clean up temp file if it exists
    if fileExists(tempPath):
      removeFile(tempPath)
    return false

  controller.mergeInProgress = false
  controller.stats.timeCompleted = getTime()

  echo &"✅ Merge completed successfully!"
  echo &"   Records kept: {controller.stats.recordsKept:,}"
  echo &"   Records dropped: {controller.stats.recordsDropped:,}"
  echo &"   Files processed: {controller.stats.filesProcessed:,}"
  echo &"   Time: {(getTime() - controller.stats.timeStarted).inSeconds:,} seconds"

  return true

proc triggerMerge*(controller: MergeController) =
  ## Trigger a manual merge operation
  withLock(controller.mergeLock):
    if controller.activeFiles.len >= controller.config.minFilesToMerge:
      let filesToMerge = selectFilesForMerge(controller)
      if filesToMerge.len > 0:
        discard performMerge(controller, filesToMerge)

proc getMergeStats*(controller: MergeController): MergeStats =
  ## Get current merge statistics
  ## Returns a copy to avoid race conditions
  withLock(controller.mergeLock):
    result = controller.stats