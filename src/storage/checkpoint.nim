## Checkpoint System for Bitcask KVS
##
## This module provides periodic checkpointing of the KeyDir
## for faster recovery and incremental checkpointing.

import std/[os, strformat, strutils, times, tables, locks, algorithm]
import ../bitbarrel/types, keydir

type
  CheckpointMetadata* = object
    timestamp*: int64
    formatVersion*: uint32
    fileId*: uint32
    keyCount*: int
    checkpointType*: string  # "full", "incremental"
    baseCheckpoint*: string  # For incremental checkpoints
    size*: int64
    crc32*: uint32

  CheckpointOptions* = object
    checkpointInterval*: int = 300      # Seconds between checkpoints
    checkpointSizeThreshold*: int64 = 10 * 1024 * 1024  # 10MB
    maxIncrementalCheckpoints*: int = 5
    enableCompression*: bool = false     # Future feature
    checkpointDir*: string = ""         # Default to dataDir

  CheckpointStats* = object
    totalCheckpoints*: int
    fullCheckpoints*: int
    incrementalCheckpoints*: int
    lastCheckpointTime*: Time
    lastCheckpointSize*: int64
    checkpointTime*: Duration
    errorCount*: int

  CheckpointSystem* = ref object
    dataDir*: string
    checkpointDir*: string
    options*: CheckpointOptions
    stats*: CheckpointStats
    lastCheckpoint*: string
    checkpointLock*: Lock
    isEnabled*: bool

const
  CHECKPOINT_VERSION* = 1'u32
  CHECKPOINT_MAGIC*: array[4, char] = ['C', 'K', 'P', 'T']
  CHECKPOINT_HEADER_SIZE* = 64

type
  CheckpointHeader* = object
    magic*: array[4, char]
    version*: uint32
    timestamp*: int64
    keyCount*: int32
    checkpointType*: uint8  # 0 = full, 1 = incremental
    reserved*: array[43, byte]  # Padding to 64 bytes

proc initCheckpointSystem*(dataDir: string, options: CheckpointOptions = CheckpointOptions()): CheckpointSystem =
  ## Initialize checkpoint system
  let cpDir = if options.checkpointDir.len > 0: options.checkpointDir else: dataDir

  result = CheckpointSystem(
    dataDir: dataDir,
    checkpointDir: cpDir,
    options: options,
    stats: CheckpointStats(),
    isEnabled: true
  )
  initLock(result.checkpointLock)

proc getCheckpointPath*(cp: CheckpointSystem, checkpointId: string, isIncremental: bool = false): string =
  ## Get path for checkpoint file
  let suffix = if isIncremental: ".inc" else: ".cpt"
  return &"{cp.checkpointDir}/{checkpointId}{suffix}"

proc findLatestCheckpoint*(cp: CheckpointSystem): tuple[path: string, metadata: CheckpointMetadata, isIncremental: bool] =
  ## Find the most recent checkpoint
  var latestCheckpoint: string = ""
  var latestMetadata: CheckpointMetadata
  var latestIsIncremental = false
  var latestTime: int64 = 0

  for kind, path in walkDir(cp.checkpointDir):
    if kind == pcFile and (path.endsWith(".cpt") or path.endsWith(".inc")):
      try:
        let file = open(path, fmRead)
        defer: file.close()

        # Read binary checkpoint header
        var header: CheckpointHeader
        let bytesRead = file.readBuffer(addr header, sizeof(CheckpointHeader))
        if bytesRead != sizeof(CheckpointHeader):
          continue

        if header.magic != CHECKPOINT_MAGIC or header.version != CHECKPOINT_VERSION:
          continue

        if header.timestamp > latestTime:
          latestTime = header.timestamp
          latestCheckpoint = path
          latestIsIncremental = path.endsWith(".inc")

          # Create metadata from header
          latestMetadata = CheckpointMetadata(
            timestamp: header.timestamp,
            formatVersion: header.version,
            keyCount: int(header.keyCount),
            checkpointType: if header.checkpointType == 0: "full" else: "incremental"
          )

      except Exception:
        continue  # Skip corrupted checkpoints

  return (latestCheckpoint, latestMetadata, latestIsIncremental)

proc writeCheckpoint*(cp: CheckpointSystem, keyDir: var KeyDir, checkpointType: string = "full", baseCheckpoint: string = ""): string =
  ## Write KeyDir checkpoint to disk
  withLock(cp.checkpointLock):
    if not cp.isEnabled:
      return ""

    let startTime = getTime()
    let timestamp = epochTime().int64
    let checkpointId = &"{timestamp:016d}"

    # Determine file path
    let isIncremental = checkpointType == "incremental"
    let checkpointPath = cp.getCheckpointPath(checkpointId, isIncremental)

    try:
      # Write to temporary file first
      let tempPath = checkpointPath & ".tmp"
      let file = open(tempPath, fmWrite)

      # Create and write binary header
      var header = CheckpointHeader(
        magic: CHECKPOINT_MAGIC,
        version: CHECKPOINT_VERSION,
        timestamp: timestamp,
        keyCount: int32(keyDir.len()),
        checkpointType: if isIncremental: 1'u8 else: 0'u8
      )
      discard file.writeBuffer(addr header, sizeof(CheckpointHeader))

      # Write KeyDir data
      var writtenKeys = 0
      var totalSize: int64 = sizeof(CheckpointHeader).int64

      for key, entry in keyDir.pairs():
        # Write key length (2 bytes)
        var keyLen = uint16(key.len)
        discard file.writeBuffer(addr keyLen, 2)

        # Write key
        if key.len > 0:
          file.write(key)

        # Write entry data (36 bytes total)
        var entryData = entry
        discard file.writeBuffer(addr entryData.fileId, 4)
        discard file.writeBuffer(addr entryData.recordPos, 8)
        discard file.writeBuffer(addr entryData.valuePos, 8)
        discard file.writeBuffer(addr entryData.valueSize, 4)
        discard file.writeBuffer(addr entryData.timestamp, 8)
        discard file.writeBuffer(addr entryData.recordSize, 4)

        writtenKeys += 1
        totalSize += 2 + key.len + 36

      file.close()

      # Atomic rename
      moveFile(tempPath, checkpointPath)

      # Update stats
      cp.stats.totalCheckpoints += 1
      if isIncremental:
        cp.stats.incrementalCheckpoints += 1
      else:
        cp.stats.fullCheckpoints += 1

      cp.stats.lastCheckpointTime = getTime()
      cp.stats.lastCheckpointSize = totalSize
      cp.stats.checkpointTime = getTime() - startTime
      cp.lastCheckpoint = checkpointId

      return checkpointId

    except Exception as e:
      cp.stats.errorCount += 1
      echo &"Error writing checkpoint: {e.msg}"

      # Clean up temp file if it exists
      let tempPath = checkpointPath & ".tmp"
      if fileExists(tempPath):
        removeFile(tempPath)

      return ""

proc loadCheckpoint*(cp: CheckpointSystem, checkpointPath: string): tuple[keyDir: KeyDir, metadata: CheckpointMetadata] =
  ## Load KeyDir from checkpoint
  try:
    let file = open(checkpointPath, fmRead)
    defer: file.close()

    # Read and validate binary header
    var header: CheckpointHeader
    let bytesRead = file.readBuffer(addr header, sizeof(CheckpointHeader))
    if bytesRead != sizeof(CheckpointHeader):
      raise newException(CatchableError, "Failed to read checkpoint header")

    if header.magic != CHECKPOINT_MAGIC:
      raise newException(CatchableError, "Invalid checkpoint magic number")

    if header.version != CHECKPOINT_VERSION:
      raise newException(CatchableError, "Unsupported checkpoint version")

    # Create metadata from header
    var metadata = CheckpointMetadata(
      timestamp: header.timestamp,
      formatVersion: header.version,
      keyCount: int(header.keyCount),
      checkpointType: if header.checkpointType == 0: "full" else: "incremental"
    )

    # Load KeyDir entries
    var keyDir = init()
    var loadedKeys = 0

    while file.getFilePos() < file.getFileSize():
      # Read key length
      var keyLen: uint16
      let keyLenRead = file.readBuffer(addr keyLen, 2)
      if keyLenRead != 2:
        break  # End of file

      # Read key
      var key = newString(keyLen)
      if keyLen > 0:
        discard file.readBuffer(addr key[0], keyLen.int)

      # Read entry (36 bytes)
      var entry: KeyDirEntry
      discard file.readBuffer(addr entry.fileId, 4)
      discard file.readBuffer(addr entry.recordPos, 8)
      discard file.readBuffer(addr entry.valuePos, 8)
      discard file.readBuffer(addr entry.valueSize, 4)
      discard file.readBuffer(addr entry.timestamp, 8)
      discard file.readBuffer(addr entry.recordSize, 4)

      # Add to KeyDir
      keyDir.add(key, entry)
      loadedKeys += 1

    if loadedKeys != metadata.keyCount:
      raise newException(CatchableError, &"Key count mismatch: loaded {loadedKeys}, expected {metadata.keyCount}")

    return (keyDir, metadata)

  except Exception as e:
    raise newException(CatchableError, &"Failed to load checkpoint: {e.msg}")

proc autoCheckpoint*(cp: CheckpointSystem, keyDir: var KeyDir): bool =
  ## Perform automatic checkpoint if conditions are met
  if not cp.isEnabled:
    return false

  # Check if enough time has passed since last checkpoint
  if cp.stats.lastCheckpointTime != Time():
    let timeSinceLast = getTime() - cp.stats.lastCheckpointTime
    if timeSinceLast.inSeconds < cp.options.checkpointInterval:
      return false

  # Check if we have enough data
  let dataSize = keyDir.len() * 100  # Estimate 100 bytes per key
  if dataSize < cp.options.checkpointSizeThreshold:
    return false

  # Perform checkpoint
  let checkpointId = cp.writeCheckpoint(keyDir, "full")
  return checkpointId.len > 0

proc autoIncrementalCheckpoint*(cp: CheckpointSystem, keyDir: var KeyDir, changedKeys: Table[string, KeyDirEntry]): bool =
  ## Perform incremental checkpoint for changed keys
  if not cp.isEnabled or changedKeys.len == 0:
    return false

  # Find latest full checkpoint
  let (latestCheckpoint, latestMetadata, _) = cp.findLatestCheckpoint()
  if latestCheckpoint.len == 0:
    # No full checkpoint, create one first
    return cp.autoCheckpoint(keyDir)

  # Create temporary KeyDir with just changed entries
  var tempKeyDir = init()
  for key, entry in changedKeys:
    tempKeyDir.add(key, entry)

  let checkpointId = cp.writeCheckpoint(tempKeyDir, "incremental", latestCheckpoint.extractFilename())
  return checkpointId.len > 0

proc applyIncrementalCheckpoint*(cp: CheckpointSystem, baseKeyDir: var KeyDir, checkpointPath: string): KeyDir =
  ## Apply incremental checkpoint to base KeyDir
  var (checkpointKeyDir, _) = cp.loadCheckpoint(checkpointPath)

  # Apply changes from checkpoint to base KeyDir
  result = baseKeyDir
  for key, entry in checkpointKeyDir.pairs():
    result.add(key, entry)

proc deleteOldCheckpoints*(cp: CheckpointSystem): int =
  ## Delete old checkpoints to save space
  var deletedCount = 0
  var checkpointFiles: seq[tuple[path: string, timestamp: int64, isIncremental: bool]]

  # Collect all checkpoint files with metadata
  for kind, path in walkDir(cp.checkpointDir):
    if kind == pcFile and (path.endsWith(".cpt") or path.endsWith(".inc")):
      try:
        let timestamp = int64(parseInt(path.extractFilename()[0..15]))
        checkpointFiles.add((path, timestamp, path.endsWith(".inc")))
      except Exception:
        continue

  # Sort by timestamp (oldest first)
  checkpointFiles.sort(proc(a, b: tuple[path: string, timestamp: int64, isIncremental: bool]): int =
    cmp(a.timestamp, b.timestamp)
  )

  # Keep latest full checkpoint and recent incremental checkpoints
  var fullCheckpointsKept = 0
  var incrementalCheckpointsKept = 0

  for file in checkpointFiles:
    if file.isIncremental:
      if incrementalCheckpointsKept >= cp.options.maxIncrementalCheckpoints:
        try:
          removeFile(file.path)
          inc deletedCount
        except Exception:
          discard
      else:
        inc incrementalCheckpointsKept
    else:
      if fullCheckpointsKept >= 2:  # Keep 2 latest full checkpoints
        try:
          removeFile(file.path)
          inc deletedCount
        except Exception:
          discard
      else:
        inc fullCheckpointsKept

  return deletedCount

proc getStats*(cp: CheckpointSystem): CheckpointStats =
  ## Get checkpoint statistics
  return cp.stats

proc setEnabled*(cp: CheckpointSystem, enabled: bool) =
  ## Enable/disable checkpointing
  withLock(cp.checkpointLock):
    cp.isEnabled = enabled

proc isRunning*(cp: CheckpointSystem): bool =
  ## Check if checkpoint system is running
  withLock(cp.checkpointLock):
    return cp.isEnabled

# Utility functions for testing
proc validateCheckpoint*(checkpointPath: string): bool =
  ## Validate checkpoint file integrity
  try:
    let file = open(checkpointPath, fmRead)
    defer: file.close()

    # Read binary header
    var header: CheckpointHeader
    let bytesRead = file.readBuffer(addr header, sizeof(CheckpointHeader))
    if bytesRead != sizeof(CheckpointHeader):
      return false

    if header.magic != CHECKPOINT_MAGIC:
      return false

    if header.version != CHECKPOINT_VERSION:
      return false

    # Would validate CRC32 in real implementation
    return true
  except Exception:
    return false

proc createTestCheckpoint*(dataDir: string, keyDir: var KeyDir): string =
  ## Create test checkpoint for unit testing
  let options = CheckpointOptions(
    checkpointInterval: 1,
    checkpointSizeThreshold: 100
  )

  let cp = initCheckpointSystem(dataDir, options)
  result = cp.writeCheckpoint(keyDir, "full")