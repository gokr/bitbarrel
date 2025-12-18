## Range Index - Key partitioning for bmRanged modes
##
## For bmRangedHash: Uses consistent hashing (CRC32) for key partitioning.
## For bmRangedCritBit: Uses ordered range partitioning based on key bounds.
## Each range maintains its own index that can be loaded/evicted from memory.

import std/[os, times, locks, algorithm, strutils]
import ../bitbarrel/types
import crc32

const
  RANGE_INDEX_MAGIC* = ['R', 'I', 'D', 'X']
  RANGE_INDEX_VERSION* = 2'u32  # Updated for min/max key support
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

proc getRangeDir*(dataDir: string, accessModel: AccessModel): string =
  ## Get directory path for ranges based on access model
  let dirName = case accessModel
                of amHash: "hash"
                of amCritBit: "critbit"
  result = dataDir / "ranges" / dirName

proc computeRangeId*(key: string, numRanges: int): RangeId =
  ## Map a key to a range using CRC32 hash (for bmRangedHash mode)
  ## Returns a value in [0, numRanges)
  let hash = crc32(key)
  result = RangeId(hash mod uint32(numRanges))

proc computeOrderedRangeId*(key: string, ranges: seq[RangeMetadata]): RangeId =
  ## Find the range that should contain the given key using binary search (for bmRangedCritBit mode)
  ## Uses ordered range partitioning based on key bounds
  ## Returns the range ID, or 0 if key is less than all ranges
  if ranges.len == 0:
    return RangeId(0)

  var left = 0
  var right = ranges.len - 1

  while left <= right:
    let mid = (left + right) div 2
    let midMeta = ranges[mid]

    # Empty range bounds mean the range accepts all keys
    if midMeta.minKey.len == 0 and midMeta.maxKey.len == 0:
      return midMeta.id

    # Check if key falls within this range
    if midMeta.minKey.len > 0 and key < midMeta.minKey:
      right = mid - 1
    elif midMeta.maxKey.len > 0 and key > midMeta.maxKey:
      left = mid + 1
    else:
      # Key is within bounds
      return midMeta.id

  # Key is outside all defined ranges - find the nearest range
  if left >= ranges.len:
    return ranges[ranges.len - 1].id
  elif right < 0:
    return ranges[0].id
  else:
    return ranges[left].id

proc prefixMightMatchRange*(prefix: string, meta: RangeMetadata): bool =
  ## Check if a prefix could match any key in a range
  ## Returns true if the range might contain keys with the given prefix
  # Empty bounds mean the range accepts all keys
  if meta.minKey.len == 0 and meta.maxKey.len == 0:
    return true

  # Check if prefix could match minKey or maxKey
  # A prefix matches if:
  # 1. minKey starts with prefix, OR
  # 2. maxKey starts with prefix, OR
  # 3. prefix is between minKey and maxKey

  let prefixLen = prefix.len

  # If minKey starts with prefix, the range contains matching keys
  if meta.minKey.len >= prefixLen and meta.minKey[0..<prefixLen] == prefix:
    return true

  # If maxKey starts with prefix, the range contains matching keys
  if meta.maxKey.len >= prefixLen and meta.maxKey[0..<prefixLen] == prefix:
    return true

  # Check if prefix falls between minKey and maxKey
  # prefix could match keys in range if: minKey <= prefix* <= maxKey
  # where prefix* is any string starting with prefix

  # minKey could be less than the smallest possible match (prefix itself)
  # maxKey could be greater than the largest possible match (prefix + '\xFF'...)
  if meta.minKey.len > 0 and prefix < meta.minKey[0..<min(prefixLen, meta.minKey.len)]:
    # Prefix is entirely before minKey - but we need to check if any prefix match is >= minKey
    # The smallest string with this prefix is just the prefix itself
    # The largest string with this prefix would be prefix + infinite 0xFF bytes
    # We need: smallest_prefix_match <= maxKey AND largest_prefix_match >= minKey
    if meta.maxKey.len > 0:
      # Check if smallest prefix match (prefix) <= maxKey
      if prefix > meta.maxKey:
        return false
      # Check if minKey could start with prefix (already checked above)
      # Check if minKey is <= largest prefix match
      # Since we can't represent largest prefix match, check if minKey starts before prefix ends
      if meta.minKey.len >= prefixLen:
        return meta.minKey[0..<prefixLen] >= prefix
      else:
        return meta.minKey <= prefix
    return true

  if meta.maxKey.len > 0 and prefix > meta.maxKey:
    # Prefix is entirely after maxKey
    return false

  # Prefix might be in range
  return true

proc rangeMightContainKeyInRange*(meta: RangeMetadata, startKey: string, endKey: string): bool =
  ## Check if a range might contain keys in [startKey, endKey)
  ## Returns true if the range might contain keys in the given range
  # Empty bounds mean the range accepts all keys
  if meta.minKey.len == 0 and meta.maxKey.len == 0:
    return true

  # Range overlaps if: range.min < endKey AND range.max >= startKey
  if meta.maxKey.len > 0 and meta.maxKey < startKey:
    return false

  if meta.minKey.len > 0 and meta.minKey >= endKey:
    return false

  return true

proc getCandidateRangesForPrefix*(index: var RangeIndex, prefix: string): seq[RangeId] =
  ## Get list of ranges that might contain keys with the given prefix
  ## For ordered partitioning, this efficiently skips irrelevant ranges
  result = @[]
  withLock(index.lock):
    for meta in index.ranges:
      if prefixMightMatchRange(prefix, meta):
        result.add(meta.id)

proc getCandidateRangesForRange*(index: var RangeIndex, startKey: string, endKey: string): seq[RangeId] =
  ## Get list of ranges that might contain keys in [startKey, endKey)
  ## For ordered partitioning, this efficiently skips irrelevant ranges
  result = @[]
  withLock(index.lock):
    for meta in index.ranges:
      if rangeMightContainKeyInRange(meta, startKey, endKey):
        result.add(meta.id)

proc updateRangeKeyBounds*(index: var RangeIndex, rangeId: RangeId, key: string) =
  ## Update the min/max key bounds for a range when a key is added
  withLock(index.lock):
    let idx = rangeId.int
    if idx < index.ranges.len:
      # Update minKey if this key is smaller or minKey is empty
      if index.ranges[idx].minKey.len == 0 or key < index.ranges[idx].minKey:
        index.ranges[idx].minKey = key

      # Update maxKey if this key is larger or maxKey is empty
      if index.ranges[idx].maxKey.len == 0 or key > index.ranges[idx].maxKey:
        index.ranges[idx].maxKey = key

      index.lastModified = getTime().toUnix()

proc initOrderedRanges*(numRanges: int): seq[RangeMetadata] =
  ## Initialize ordered ranges with alphabetic boundaries
  ## Creates numRanges partitions with initial boundaries based on common prefixes
  result = newSeq[RangeMetadata](numRanges)

  # For initial allocation, divide the key space roughly equally
  # Using printable ASCII characters (0x20 to 0x7E)
  let charsPerRange = max(1, 95 div numRanges)  # 95 printable ASCII chars

  for i in 0..<numRanges:
    let startChar = chr(0x20 + i * charsPerRange)
    let endChar = if i == numRanges - 1:
                    chr(0x7E)  # Last range includes everything up to ~
                  else:
                    chr(0x20 + (i + 1) * charsPerRange - 1)

    result[i] = RangeMetadata(
      id: RangeId(i),
      keyCount: 0,
      lastAccess: 0,
      hintPath: "",
      isLoaded: false,
      isDirty: false,
      minKey: $startChar,  # Initial boundary
      maxKey: $endChar     # Initial boundary
    )

proc getRangeHintPath*(dataDir: string, rangeId: RangeId, accessModel: AccessModel): string =
  ## Get the hint file path for a specific range
  let ext = case accessModel
            of amHash: ".rhint"
            of amCritBit: ".chint"
  let dirName = case accessModel
                of amHash: "hash"
                of amCritBit: "critbit"
  result = dataDir / "ranges" / dirName / ("range_" & $rangeId & ext)

proc getRangeHintPath*(dataDir: string, rangeId: RangeId): string =
  ## Backward compatibility - assume hash mode
  getRangeHintPath(dataDir, rangeId, amHash)

proc initRangeIndex*(numRanges: int, accessModel: AccessModel, dataDir: string): RangeIndex =
  ## Initialize a new range index with N partitions
  result = RangeIndex()
  result.dataDir = dataDir
  result.numRanges = numRanges
  result.ranges = newSeq[RangeMetadata](numRanges)
  result.totalKeys = 0
  result.created = getTime().toUnix()
  result.lastModified = result.created
  initLock(result.lock)

  # Create range directory if needed
  let rangeDir = getRangeDir(dataDir, accessModel)
  if not dirExists(rangeDir):
    createDir(rangeDir)

  # Initialize range metadata
  for i in 0..<numRanges:
    result.ranges[i] = RangeMetadata(
      id: RangeId(i),
      keyCount: 0,
      lastAccess: 0,
      hintPath: getRangeHintPath(dataDir, RangeId(i), accessModel),
      isLoaded: false,
      isDirty: false
    )

# Backward compatibility
proc initRangeIndex*(numRanges: int, dataDir: string): RangeIndex =
  ## Initialize a new range index with hash access model (backward compatibility)
  initRangeIndex(numRanges, amHash, dataDir)

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

proc writeString(file: File, s: string) =
  ## Write a length-prefixed string to file
  var len = s.len.uint32
  discard file.writeBuffer(addr len, sizeof(uint32))
  if s.len > 0:
    discard file.writeBuffer(unsafeAddr s[0], s.len)

proc readString(file: File): string =
  ## Read a length-prefixed string from file
  var len: uint32
  let lenRead = file.readBuffer(addr len, sizeof(uint32))
  if lenRead != sizeof(uint32):
    return ""
  if len == 0:
    return ""
  result = newString(len)
  let strRead = file.readBuffer(addr result[0], len.int)
  if strRead != len.int:
    result = ""

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

      # Write range metadata entries (with minKey/maxKey for v2)
      for meta in index.ranges:
        var id = meta.id
        var keyCount = meta.keyCount
        var isDirty = if meta.isDirty: 1'u8 else: 0'u8

        discard file.writeBuffer(addr id, sizeof(RangeId))
        discard file.writeBuffer(addr keyCount, sizeof(int64))
        discard file.writeBuffer(addr isDirty, 1)

        # Write minKey and maxKey (v2 fields)
        file.writeString(meta.minKey)
        file.writeString(meta.maxKey)

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
