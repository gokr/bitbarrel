## Range Index - Hash-based key partitioning for bmRanged mode
##
## Manages partitioning of keys into ranges using consistent hashing.
## Each range maintains its own KeyDir that can be loaded/evicted from memory.

import std/[os, times, locks]
import ../bitbarrel/types
import crc32

const
  RANGE_INDEX_MAGIC* = ['R', 'I', 'D', 'X']
  RANGE_INDEX_VERSION* = 1'u32
  RANGE_INDEX_HEADER_SIZE* = 64

type
  RangeIndexHeader* = object
    magic*: array[4, char]    # "RIDX"
    version*: uint32          # Format version
    numRanges*: uint32        # Number of partitions
    totalKeys*: int64         # Total key count across all ranges
    created*: int64           # Creation timestamp
    lastModified*: int64      # Last modification timestamp
    checksum*: uint32         # Header checksum
    reserved*: array[28, byte]

  RangeIndex* = object
    dataDir*: string
    numRanges*: int
    ranges*: seq[RangeMetadata]
    totalKeys*: int64
    created*: int64
    lastModified*: int64
    lock*: Lock

proc computeRangeId*(key: string, numRanges: int): RangeId =
  ## Map a key to a range using CRC32 hash
  ## Returns a value in [0, numRanges)
  let hash = crc32(key)
  result = RangeId(hash mod uint32(numRanges))

proc getRangeHintPath*(dataDir: string, rangeId: RangeId): string =
  ## Get the hint file path for a specific range
  result = dataDir / "ranges" / ("range_" & $rangeId & ".rhint")

proc initRangeIndex*(numRanges: int, dataDir: string): RangeIndex =
  ## Initialize a new range index with N partitions
  result = RangeIndex()
  result.dataDir = dataDir
  result.numRanges = numRanges
  result.ranges = newSeq[RangeMetadata](numRanges)
  result.totalKeys = 0
  result.created = getTime().toUnix()
  result.lastModified = result.created
  initLock(result.lock)

  # Initialize range metadata
  for i in 0..<numRanges:
    result.ranges[i] = RangeMetadata(
      id: RangeId(i),
      keyCount: 0,
      lastAccess: 0,
      hintPath: getRangeHintPath(dataDir, RangeId(i)),
      isLoaded: false,
      isDirty: false
    )

proc getRangeMetadata*(index: var RangeIndex, rangeId: RangeId): var RangeMetadata =
  ## Get metadata for a specific range
  withLock(index.lock):
    result = index.ranges[rangeId.int]

proc updateRangeKeyCount*(index: var RangeIndex, rangeId: RangeId, delta: int) =
  ## Update the key count for a range
  withLock(index.lock):
    index.ranges[rangeId.int].keyCount += delta
    index.totalKeys += delta
    index.lastModified = getTime().toUnix()

proc markRangeDirty*(index: var RangeIndex, rangeId: RangeId) =
  ## Mark a range as dirty (needs flush)
  withLock(index.lock):
    index.ranges[rangeId.int].isDirty = true
    index.lastModified = getTime().toUnix()

proc markRangeClean*(index: var RangeIndex, rangeId: RangeId) =
  ## Mark a range as clean (flushed)
  withLock(index.lock):
    index.ranges[rangeId.int].isDirty = false

proc markRangeLoaded*(index: var RangeIndex, rangeId: RangeId) =
  ## Mark a range as loaded in memory
  withLock(index.lock):
    index.ranges[rangeId.int].isLoaded = true
    index.ranges[rangeId.int].lastAccess = getTime().toUnix()

proc markRangeUnloaded*(index: var RangeIndex, rangeId: RangeId) =
  ## Mark a range as unloaded from memory
  withLock(index.lock):
    index.ranges[rangeId.int].isLoaded = false

proc touchRange*(index: var RangeIndex, rangeId: RangeId) =
  ## Update last access time for LRU tracking
  withLock(index.lock):
    index.ranges[rangeId.int].lastAccess = getTime().toUnix()

proc getLoadedRanges*(index: var RangeIndex): seq[RangeId] =
  ## Get list of currently loaded ranges
  withLock(index.lock):
    result = @[]
    for meta in index.ranges:
      if meta.isLoaded:
        result.add(meta.id)

proc getDirtyRanges*(index: var RangeIndex): seq[RangeId] =
  ## Get list of dirty ranges that need flushing
  withLock(index.lock):
    result = @[]
    for meta in index.ranges:
      if meta.isDirty:
        result.add(meta.id)

proc getTotalKeys*(index: var RangeIndex): int64 =
  ## Get total key count across all ranges
  withLock(index.lock):
    result = index.totalKeys

proc deinit*(index: var RangeIndex) =
  ## Cleanup resources
  deinitLock(index.lock)

# Persistence functions

proc calculateHeaderChecksum(header: var RangeIndexHeader): uint32 =
  ## Calculate checksum for header (excluding checksum field)
  var tempHeader = header
  tempHeader.checksum = 0
  var data = newString(RANGE_INDEX_HEADER_SIZE)
  copyMem(addr data[0], addr tempHeader, RANGE_INDEX_HEADER_SIZE)
  result = crc32(data)

proc saveRangeIndex*(index: var RangeIndex, path: string): bool =
  ## Save range index to disk
  ## Returns true on success
  let tempPath = path & ".tmp"

  withLock(index.lock):
    try:
      let file = open(tempPath, fmWrite)
      defer: file.close()

      # Write header
      var header = RangeIndexHeader(
        magic: RANGE_INDEX_MAGIC,
        version: RANGE_INDEX_VERSION,
        numRanges: index.numRanges.uint32,
        totalKeys: index.totalKeys,
        created: index.created,
        lastModified: index.lastModified,
        checksum: 0
      )
      header.checksum = calculateHeaderChecksum(header)

      let headerWritten = file.writeBuffer(addr header, RANGE_INDEX_HEADER_SIZE)
      if headerWritten != RANGE_INDEX_HEADER_SIZE:
        return false

      # Write range metadata entries
      for meta in index.ranges:
        var id = meta.id
        var keyCount = meta.keyCount
        var isDirty = if meta.isDirty: 1'u8 else: 0'u8

        discard file.writeBuffer(addr id, sizeof(RangeId))
        discard file.writeBuffer(addr keyCount, sizeof(int64))
        discard file.writeBuffer(addr isDirty, 1)

      file.flushFile()

      # Atomic rename
      moveFile(tempPath, path)
      return true

    except IOError, OSError:
      if fileExists(tempPath):
        removeFile(tempPath)
      return false

proc loadRangeIndex*(path: string, dataDir: string): tuple[index: RangeIndex, success: bool] =
  ## Load range index from disk
  ## Returns (index, success)

  result.success = false

  if not fileExists(path):
    return

  try:
    let file = open(path, fmRead)
    defer: file.close()

    # Read header
    var header: RangeIndexHeader
    let headerRead = file.readBuffer(addr header, RANGE_INDEX_HEADER_SIZE)
    if headerRead != RANGE_INDEX_HEADER_SIZE:
      return

    # Validate magic
    if header.magic != RANGE_INDEX_MAGIC:
      return

    # Validate version
    if header.version != RANGE_INDEX_VERSION:
      return

    # Validate checksum
    let storedChecksum = header.checksum
    let computedChecksum = calculateHeaderChecksum(header)
    if storedChecksum != computedChecksum:
      return

    # Initialize index
    result.index = initRangeIndex(header.numRanges.int, dataDir)
    result.index.totalKeys = header.totalKeys
    result.index.created = header.created
    result.index.lastModified = header.lastModified

    # Read range metadata entries
    for i in 0..<header.numRanges.int:
      var id: RangeId
      var keyCount: int64
      var isDirty: uint8

      let idRead = file.readBuffer(addr id, sizeof(RangeId))
      let keyCountRead = file.readBuffer(addr keyCount, sizeof(int64))
      let isDirtyRead = file.readBuffer(addr isDirty, 1)

      if idRead != sizeof(RangeId) or keyCountRead != sizeof(int64) or isDirtyRead != 1:
        result.index.deinit()
        result.success = false
        return

      result.index.ranges[i].id = id
      result.index.ranges[i].keyCount = keyCount
      result.index.ranges[i].isDirty = isDirty != 0
      result.index.ranges[i].hintPath = getRangeHintPath(dataDir, id)

    result.success = true

  except IOError:
    result.success = false

proc ensureRangeDir*(dataDir: string): bool =
  ## Ensure the ranges directory exists
  let rangeDir = dataDir / "ranges"
  try:
    if not dirExists(rangeDir):
      createDir(rangeDir)
    return true
  except OSError:
    return false

proc getRangeIndexPath*(dataDir: string): string =
  ## Get the path for the range index file
  result = dataDir / "ranges" / "range_index.meta"
