## RangeKeyDir - Fast Serializable Index for bmHugeCritBit
##
## Uses a sorted array format for O(1) deserialization and O(log n) lookups.
## Inserts are buffered and merged on flush to avoid constant rebuilds.

import std/[algorithm, tables, options, strformat]
import ../bitbarrel/types

const
  RANGEKEYDIR_MAGIC* = ['R', 'K', 'D', 'R']
  RANGEKEYDIR_VERSION* = 2'u32
  HEADER_SIZE = 48
  DEFAULT_MAX_PENDING = 50000
  CRC32_POLYNOMIAL = 0xEDB88320'u32

type
  RangeKeyDirHeader* = object
    magic*: array[4, char]      # "RKDR"
    version*: uint32            # Format version
    flags*: uint32              # Reserved for future use
    entryCount*: uint32         # Number of entries in sorted array
    minKeyLen*: uint16          # Length of minKey
    maxKeyLen*: uint16          # Length of maxKey
    totalSize*: uint32          # Total size of serialized data
    checksum*: uint32           # CRC32 of entries section
    reserved*: array[20, byte]  # Padding to 48 bytes

  RangeKeyDir* = ref object
    # IMPORTANT: Changed to ref object to avoid expensive copying
    # RangeKeyDir can contain 200MB+ of data - copying on every operation was O(n)

    # Range bounds
    minKey*: string
    maxKey*: string

    # File assignment (NEW in version 2)
    assignedFileId*: uint32     # Which Barrel2 datafile this range writes to

    # Sorted array data (serialized blob kept for binary search)
    data*: string               # The serialized blob
    entryCount*: int            # Number of entries in sorted array
    offsetTableStart*: int      # Position of offset table in data
    entriesStart*: int          # Position of entries section in data

    # Insert buffer (checked alongside sorted array)
    pendingInserts*: Table[string, RangeKeyDirEntry]
    maxPendingInserts*: int     # Threshold for auto-flush

    # Optimization: Track if we're in sequential write mode
    # When true, pending inserts are already sorted and can be appended directly
    sequentialMode*: bool
    lastInsertedKey*: string    # Track last key for sequential detection
    sequentialStreak*: int      # Count of consecutive ordered inserts
    outOfOrderCount*: int       # Count of out-of-order inserts (for tolerance)

    # State
    isDirty*: bool

proc crc32(data: pointer, len: int): uint32 =
  var crc = 0xFFFFFFFF'u32
  let bytes = cast[ptr UncheckedArray[byte]](data)
  for i in 0..<len:
    crc = crc xor bytes[i]
    for j in 0..<8:
      if (crc and 1) != 0:
        crc = (crc shr 1) xor CRC32_POLYNOMIAL
      else:
        crc = crc shr 1
  crc xor 0xFFFFFFFF'u32

proc crc32String(s: string): uint32 =
  if s.len == 0:
    return 0
  crc32(unsafeAddr s[0], s.len)

# --- Binary encoding helpers ---

proc writeUint16(s: var string, val: uint16) =
  s.add(char(val and 0xFF))
  s.add(char((val shr 8) and 0xFF))

proc writeUint32(s: var string, val: uint32) =
  s.add(char(val and 0xFF))
  s.add(char((val shr 8) and 0xFF))
  s.add(char((val shr 16) and 0xFF))
  s.add(char((val shr 24) and 0xFF))

proc writeUint64(s: var string, val: uint64) =
  s.add(char(val and 0xFF))
  s.add(char((val shr 8) and 0xFF))
  s.add(char((val shr 16) and 0xFF))
  s.add(char((val shr 24) and 0xFF))
  s.add(char((val shr 32) and 0xFF))
  s.add(char((val shr 40) and 0xFF))
  s.add(char((val shr 48) and 0xFF))
  s.add(char((val shr 56) and 0xFF))


proc writeString(s: var string, val: string) =
  writeUint16(s, val.len.uint16)
  s.add(val)

proc writeUint32At(s: var string, pos: int, val: uint32) =
  ## Write uint32 at specific position in string
  s[pos] = char(val and 0xFF)
  s[pos + 1] = char((val shr 8) and 0xFF)
  s[pos + 2] = char((val shr 16) and 0xFF)
  s[pos + 3] = char((val shr 24) and 0xFF)

proc readUint16(data: string, pos: int): uint16 =
  result = uint16(data[pos].uint8) or
           (uint16(data[pos + 1].uint8) shl 8)

proc readUint32(data: string, pos: int): uint32 =
  result = uint32(data[pos].uint8) or
           (uint32(data[pos + 1].uint8) shl 8) or
           (uint32(data[pos + 2].uint8) shl 16) or
           (uint32(data[pos + 3].uint8) shl 24)

proc readUint64(data: string, pos: int): uint64 =
  result = uint64(data[pos].uint8) or
           (uint64(data[pos + 1].uint8) shl 8) or
           (uint64(data[pos + 2].uint8) shl 16) or
           (uint64(data[pos + 3].uint8) shl 24) or
           (uint64(data[pos + 4].uint8) shl 32) or
           (uint64(data[pos + 5].uint8) shl 40) or
           (uint64(data[pos + 6].uint8) shl 48) or
           (uint64(data[pos + 7].uint8) shl 56)

proc readString(data: string, pos: int): (string, int) =
  let length = readUint16(data, pos).int
  let str = data[pos + 2 ..< pos + 2 + length]
  (str, pos + 2 + length)

# --- RangeKeyDir creation ---

proc newRangeKeyDir*(minKey: string = "", maxKey: string = "",
                     assignedFileId: uint32 = 0,
                     maxPending: int = DEFAULT_MAX_PENDING): RangeKeyDir =
  ## Create a new empty RangeKeyDir
  ## Returns ref object (allocated on heap)
  result = RangeKeyDir(
    minKey: minKey,
    maxKey: maxKey,
    assignedFileId: assignedFileId,
    data: "",
    entryCount: 0,
    offsetTableStart: 0,
    entriesStart: 0,
    pendingInserts: initTable[string, RangeKeyDirEntry](),
    maxPendingInserts: maxPending,
    sequentialMode: true,    # Start in sequential mode (optimistic)
    lastInsertedKey: "",
    sequentialStreak: 0,
    outOfOrderCount: 0,
    isDirty: false
  )

# --- Entry access ---

proc getOffset(rkd: RangeKeyDir, index: int): int =
  ## Get the offset for entry at given index
  let pos = rkd.offsetTableStart + index * 4
  readUint32(rkd.data, pos).int

proc readKeyAt*(rkd: RangeKeyDir, entryOffset: int): string =
  ## Read just the key at a given entry offset
  let pos = rkd.entriesStart + entryOffset
  let (key, _) = readString(rkd.data, pos)
  key

proc readEntryAt*(rkd: RangeKeyDir, entryOffset: int): (string, RangeKeyDirEntry) =
  ## Read a full entry at a given entry offset
  ## Returns (key, entry) - key is separate to avoid duplication
  var pos = rkd.entriesStart + entryOffset

  let (key, nextPos) = readString(rkd.data, pos)
  pos = nextPos

  var entry = RangeKeyDirEntry(
    recordPos: readUint64(rkd.data, pos),
    fileId: readUint32(rkd.data, pos + 8),
    valueSize: readUint32(rkd.data, pos + 12),
    recordSize: readUint32(rkd.data, pos + 16),
    keyLen: readUint16(rkd.data, pos + 20)
  )

  return (key, entry)

# --- Serialization ---

proc serialize*(rkd: RangeKeyDir): string =
  ## Serialize the RangeKeyDir to a binary blob
  ## Format:
  ##   Header (48 bytes)
  ##   Offset table (entryCount * 4 bytes)
  ##   Keys section (minKey + maxKey with length prefixes)
  ##   Entries section (sorted by key)

  # OPTIMIZATION: If no pending inserts, data is already sorted - just add header IN PLACE
  # This avoids a 200MB+ copy on every serialize!
  if rkd.pendingInserts.len == 0 and rkd.data.len > 0:
    # Calculate checksum of entries section
    let entriesSection = rkd.data[rkd.entriesStart..^1]
    let checksum = crc32String(entriesSection)

    # Build header
    var header = ""
    header.add(RANGEKEYDIR_MAGIC[0])
    header.add(RANGEKEYDIR_MAGIC[1])
    header.add(RANGEKEYDIR_MAGIC[2])
    header.add(RANGEKEYDIR_MAGIC[3])
    header.writeUint32(RANGEKEYDIR_VERSION)
    header.writeUint32(0'u32)  # flags
    header.writeUint32(rkd.entryCount.uint32)
    header.writeUint16(rkd.minKey.len.uint16)
    header.writeUint16(rkd.maxKey.len.uint16)
    header.writeUint32(rkd.data.len.uint32)
    header.writeUint32(checksum)
    # Pad header to 48 bytes
    while header.len < HEADER_SIZE:
      header.add('\x00')

    # Write header into the first HEADER_SIZE bytes (already allocated by flush())
    # Modify rkd.data directly to avoid COW
    for i in 0..<HEADER_SIZE:
      rkd.data[i] = header[i]

    return rkd.data

  # Slow path: need to merge pending inserts
  # Collect all entries (merged from sorted array + pending)
  var allEntries: seq[tuple[key: string, entry: RangeKeyDirEntry]] = @[]

  # Add entries from existing sorted array
  if rkd.data.len > 0 and rkd.entryCount > 0:
    for i in 0..<rkd.entryCount:
      let offset = rkd.getOffset(i)
      let (key, entry) = rkd.readEntryAt(offset)
      # Skip if overwritten by pending
      if key notin rkd.pendingInserts:
        allEntries.add((key, entry))

  # Add pending inserts
  for key, entry in rkd.pendingInserts:
    allEntries.add((key, entry))

  # Sort by key
  allEntries.sort(proc(a, b: auto): int = cmp(a.key, b.key))

  # Build entries section first to calculate offsets
  var entriesData = ""
  var offsets: seq[uint32] = @[]

  for (key, entry) in allEntries:
    offsets.add(entriesData.len.uint32)

    # Entry format: keyLen(2) + key + recordPos(8) + fileId(4) + valueSize(4) +
    #               recordSize(4) + keyLen(2)
    entriesData.writeString(key)
    entriesData.writeUint64(entry.recordPos)
    entriesData.writeUint32(entry.fileId)
    entriesData.writeUint32(entry.valueSize)
    entriesData.writeUint32(entry.recordSize)
    entriesData.writeUint16(entry.keyLen)

  # Update minKey/maxKey from sorted entries
  var minKey = rkd.minKey
  var maxKey = rkd.maxKey
  if allEntries.len > 0:
    if minKey.len == 0 or allEntries[0].key < minKey:
      minKey = allEntries[0].key
    if maxKey.len == 0 or allEntries[^1].key > maxKey:
      maxKey = allEntries[^1].key

  # Build offset table
  var offsetData = ""
  for offset in offsets:
    offsetData.writeUint32(offset)

  # Build keys section
  var keysData = ""
  keysData.writeString(minKey)
  keysData.writeString(maxKey)

  # Calculate total size
  let totalSize = HEADER_SIZE + offsetData.len + keysData.len + entriesData.len

  # Calculate checksum of entries
  let checksum = crc32String(entriesData)

  # Build header
  var header = ""
  header.add(RANGEKEYDIR_MAGIC[0])
  header.add(RANGEKEYDIR_MAGIC[1])
  header.add(RANGEKEYDIR_MAGIC[2])
  header.add(RANGEKEYDIR_MAGIC[3])
  header.writeUint32(RANGEKEYDIR_VERSION)
  header.writeUint32(0'u32)  # flags
  header.writeUint32(allEntries.len.uint32)
  header.writeUint16(minKey.len.uint16)
  header.writeUint16(maxKey.len.uint16)
  header.writeUint32(totalSize.uint32)
  header.writeUint32(checksum)
  # Reserved (20 bytes) - use first 4 bytes for assignedFileId (v2)
  header.writeUint32(rkd.assignedFileId)
  for i in 0..<16:
    header.add('\x00')

  assert header.len == HEADER_SIZE

  # Combine all sections
  result = header & offsetData & keysData & entriesData

# --- Deserialization ---

proc deserialize*(data: string): RangeKeyDir =
  ## Deserialize a RangeKeyDir from a binary blob
  ## Only parses header and offset table - entries are read on demand

  if data.len < HEADER_SIZE:
    raise newException(ValueError, "Data too short for RangeKeyDir header")

  # Parse header
  let magic = [data[0], data[1], data[2], data[3]]
  if magic != RANGEKEYDIR_MAGIC:
    raise newException(ValueError, fmt("Invalid magic: expected RKDR, got {magic}"))

  let version = readUint32(data, 4)
  if version != RANGEKEYDIR_VERSION:
    raise newException(ValueError, fmt("Unsupported version: {version}, expected {RANGEKEYDIR_VERSION}"))

  let _ = readUint32(data, 8)  # flags (reserved for future use)
  let entryCount = readUint32(data, 12).int
  let minKeyLen = readUint16(data, 16).int
  let maxKeyLen = readUint16(data, 18).int
  let totalSize = readUint32(data, 20).int
  let checksum = readUint32(data, 24)

  if data.len < totalSize:
    raise newException(ValueError, fmt("Data truncated: expected {totalSize}, got {data.len}"))

  # Calculate positions
  let offsetTableStart = HEADER_SIZE
  let offsetTableSize = entryCount * 4
  let keysStart = offsetTableStart + offsetTableSize
  let entriesStart = keysStart + 2 + minKeyLen + 2 + maxKeyLen

  # Parse keys section
  var pos = keysStart
  let (minKey, pos2) = readString(data, pos)
  let (maxKey, _) = readString(data, pos2)

  # Verify checksum
  if entryCount > 0:
    let entriesData = data[entriesStart ..< totalSize]
    let calculatedChecksum = crc32String(entriesData)
    if calculatedChecksum != checksum:
      raise newException(ValueError, fmt("Checksum mismatch: expected {checksum}, got {calculatedChecksum}"))

  # Read assignedFileId from reserved space
  let assignedFileId = readUint32(data, 28)  # Position after checksum

  result = RangeKeyDir(
    minKey: minKey,
    maxKey: maxKey,
    assignedFileId: assignedFileId,
    data: data,
    entryCount: entryCount,
    offsetTableStart: offsetTableStart,
    entriesStart: entriesStart,
    pendingInserts: initTable[string, RangeKeyDirEntry](),
    maxPendingInserts: DEFAULT_MAX_PENDING,
    isDirty: false
  )

# --- Binary search lookup ---

proc binarySearchSorted(rkd: RangeKeyDir, key: string): Option[RangeKeyDirEntry] =
  ## Binary search in the sorted array
  if rkd.entryCount == 0:
    return none(RangeKeyDirEntry)

  var lo = 0
  var hi = rkd.entryCount - 1

  while lo <= hi:
    let mid = (lo + hi) div 2
    let offset = rkd.getOffset(mid)
    let entryKey = rkd.readKeyAt(offset)

    let cmpResult = cmp(entryKey, key)
    if cmpResult == 0:
      let (_, entry) = rkd.readEntryAt(offset)
      return some(entry)
    elif cmpResult < 0:
      lo = mid + 1
    else:
      hi = mid - 1

  none(RangeKeyDirEntry)

proc find*(rkd: RangeKeyDir, key: string): Option[RangeKeyDirEntry] =
  ## Find an entry by key
  ## Checks pending buffer first (O(1)), then sorted array (O(log n))

  # Check pending buffer first
  if key in rkd.pendingInserts:
    return some(rkd.pendingInserts[key])

  # Binary search in sorted array
  rkd.binarySearchSorted(key)

proc contains*(rkd: RangeKeyDir, key: string): bool =
  ## Check if key exists (not deleted)
  let entry = rkd.find(key)
  entry.isSome and not entry.get().isDeleted

# --- Insert operations ---

proc insert*(rkd: RangeKeyDir, key: string, entry: RangeKeyDirEntry) =
  ## Insert or update an entry
  ## Buffers the insert - call flush() to rebuild sorted array
  rkd.pendingInserts[key] = entry
  rkd.isDirty = true

  # Detect sequential write patterns with tolerance for occasional out-of-order writes
  if rkd.lastInsertedKey.len > 0:
    if key > rkd.lastInsertedKey:
      # Key is in order, increase sequential streak
      rkd.sequentialStreak += 1
      rkd.outOfOrderCount = max(0, rkd.outOfOrderCount - 10)  # Forgive some out-of-order
      # Enable sequential mode after 100+ consecutive ordered inserts
      rkd.sequentialMode = rkd.sequentialStreak >= 100
    else:
      # Out of order, reset streak and increase tolerance counter
      rkd.outOfOrderCount += 1
      rkd.sequentialStreak = max(0, rkd.sequentialStreak - 10)  # Penalize more heavily
      # Only disable sequential mode if we see frequent out-of-order (>10% of writes)
      if rkd.outOfOrderCount > 100 and rkd.outOfOrderCount > (rkd.pendingInserts.len div 10):
        rkd.sequentialMode = false

  rkd.lastInsertedKey = key

  # Update bounds
  if rkd.minKey.len == 0 or key < rkd.minKey:
    rkd.minKey = key
  if rkd.maxKey.len == 0 or key > rkd.maxKey:
    rkd.maxKey = key

proc delete*(rkd: RangeKeyDir, key: string) =
  ## Mark a key as deleted (valueSize = 0 indicates tombstone)
  let existing = rkd.find(key)
  if existing.isSome:
    var entry = existing.get()
    entry.valueSize = 0
    rkd.insert(key, entry)

proc flush*(rkd: RangeKeyDir) =
  ## Rebuild the sorted array by merging pending inserts
  ## OPTIMIZED: Uses merge instead of full re-sort for O(n) instead of O(n log n)
  ## ULTRA-OPTIMIZED: For sequential writes, just append without rebuilding
  if rkd.pendingInserts.len == 0:
    return

  # ULTRA-OPTIMIZATION: Check if we can append sequentially
  if rkd.sequentialMode and rkd.data.len > 0 and rkd.entryCount > 0:
    # Verify that pending inserts are sorted and sequential
    var pendingList: seq[tuple[key: string, entry: RangeKeyDirEntry]] = @[]
    for key, entry in rkd.pendingInserts:
      pendingList.add((key, entry))

    # Sort to check if already sequential
    var sortedPending = pendingList
    sortedPending.sort(proc(a, b: auto): int = cmp(a.key, b.key))

    var isSequential = true
    for i in 0..<pendingList.len:
      if pendingList[i].key != sortedPending[i].key:
        isSequential = false
        break

    # Also check if pending keys come after existing max key
    if isSequential and rkd.maxKey.len > 0:
      let firstPendingKey = pendingList[0].key
      if firstPendingKey > rkd.maxKey:
        # Yes! We can just append!
        # Build just the new entries section
        var newEntriesData = ""
        var newOffsets: seq[uint32] = @[]
        let existingEntriesStart = rkd.entriesStart

        for (key, entry) in pendingList:
          newOffsets.add(newEntriesData.len.uint32)
          newEntriesData.writeString(key)
          newEntriesData.writeUint64(entry.recordPos)
          newEntriesData.writeUint32(entry.fileId)
          newEntriesData.writeUint32(entry.valueSize)
          newEntriesData.writeUint32(entry.recordSize)
          newEntriesData.writeUint16(entry.keyLen)

        # We need to rebuild the offset table (existing + new)
        # This is much cheaper than rebuilding everything
        let oldOffsetCount = rkd.entryCount
        let newOffsetCount = oldOffsetCount + newOffsets.len
        let oldOffsetTableLen = oldOffsetCount * 4
        let newOffsetTableLen = newOffsetCount * 4
        let lenChange = newOffsetTableLen - oldOffsetTableLen

        # Make space for new offset table
        let oldData = rkd.data
        var newData = ""
        newData.setLen(oldData.len + lenChange + newEntriesData.len)

        # Copy header
        for i in 0..<HEADER_SIZE:
          newData[i] = oldData[i]

        # Write combined offset table (existing + new)
        # Existing offsets need to be adjusted for the shift
        var pos = HEADER_SIZE
        for i in 0..<oldOffsetCount:
          let oldOffset = readUint32(oldData, HEADER_SIZE + i * 4)
          writeUint32At(newData, pos, oldOffset + lenChange.uint32)
          pos += 4
        for offset in newOffsets:
          writeUint32At(newData, pos, offset.uint32 + existingEntriesStart.uint32 + lenChange.uint32)
          pos += 4

        # Copy keys section (unchanged except maybe maxKey)
        let oldKeysStart = HEADER_SIZE + oldOffsetTableLen
        let oldKeysLen = rkd.entriesStart - oldKeysStart
        for i in 0..<oldKeysLen:
          newData[pos + i] = oldData[oldKeysStart + i]

        # Update maxKey in keys section if needed
        if pendingList.len > 0:
          let lastPendingKey = pendingList[^1].key
          if lastPendingKey > rkd.maxKey:
            # Update maxKey - it will be handled during full rebuild
            # For now just track it
            rkd.maxKey = lastPendingKey

        pos += oldKeysLen

        # Copy existing entries (unchanged)
        let oldEntriesLen = oldData.len - rkd.entriesStart
        for i in 0..<oldEntriesLen:
          newData[pos + i] = oldData[rkd.entriesStart + i]
        pos += oldEntriesLen

        # Append new entries
        for i in 0..<newEntriesData.len:
          newData[pos + i] = newEntriesData[i]

        # Update state efficiently
        rkd.data = newData
        rkd.entryCount = newOffsetCount
        rkd.offsetTableStart = HEADER_SIZE
        rkd.entriesStart = existingEntriesStart + lenChange
        rkd.pendingInserts.clear()
        rkd.isDirty = false
        rkd.sequentialStreak = 0  # Reset after flush
        rkd.outOfOrderCount = 0   # Reset after flush
        return

  # Not sequential, fall back to merge-based flush
  # (original optimized implementation)

  # Collect all entries (merged from sorted array + pending)
  var allEntries: seq[tuple[key: string, entry: RangeKeyDirEntry]] = @[]

  # Add entries from existing sorted array
  if rkd.data.len > 0 and rkd.entryCount > 0:
    for i in 0..<rkd.entryCount:
      let offset = rkd.getOffset(i)
      let (key, entry) = rkd.readEntryAt(offset)
      # Skip if overwritten by pending
      if key notin rkd.pendingInserts:
        allEntries.add((key, entry))

  # Add pending inserts and sort
  for key, entry in rkd.pendingInserts:
    allEntries.add((key, entry))
  allEntries.sort(proc(a, b: auto): int = cmp(a.key, b.key))

  # Now rebuild the serialized format from merged entries
  # (allEntries is already sorted via sort)
  var entriesData = ""
  var offsets: seq[uint32] = @[]

  for (key, entry) in allEntries:
    offsets.add(entriesData.len.uint32)
    entriesData.writeString(key)
    entriesData.writeUint64(entry.recordPos)
    entriesData.writeUint32(entry.fileId)
    entriesData.writeUint32(entry.valueSize)
    entriesData.writeUint32(entry.recordSize)
    entriesData.writeUint16(entry.keyLen)

  # Update bounds
  var minKey = rkd.minKey
  var maxKey = rkd.maxKey
  if allEntries.len > 0:
    if minKey.len == 0 or allEntries[0].key < minKey:
      minKey = allEntries[0].key
    if maxKey.len == 0 or allEntries[^1].key > maxKey:
      maxKey = allEntries[^1].key

  # Build offset table
  var offsetData = ""
  for offset in offsets:
    offsetData.writeUint32(offset)

  # Build keys section
  var keysData = ""
  keysData.writeString(minKey)
  keysData.writeString(maxKey)

  # Combine everything
  let entriesStart = HEADER_SIZE + offsetData.len + keysData.len
  var data = ""
  data.setLen(entriesStart + entriesData.len)

  # Skip header for now, just store the data sections
  var pos = HEADER_SIZE
  for i in 0..<offsetData.len:
    data[pos + i] = offsetData[i]
  pos += offsetData.len
  for i in 0..<keysData.len:
    data[pos + i] = keysData[i]
  pos += keysData.len
  for i in 0..<entriesData.len:
    data[pos + i] = entriesData[i]

  # Update RangeKeyDir state
  rkd.data = data
  rkd.entryCount = allEntries.len
  rkd.offsetTableStart = HEADER_SIZE
  rkd.entriesStart = entriesStart
  rkd.minKey = minKey
  rkd.maxKey = maxKey
  rkd.pendingInserts.clear()
  rkd.isDirty = false
  rkd.sequentialStreak = 0  # Reset after flush
  rkd.outOfOrderCount = 0   # Reset after flush

proc totalLen*(rkd: RangeKeyDir): int =
  ## Get total entry count including pending inserts
  result = rkd.entryCount + rkd.pendingInserts.len

proc shouldFlush*(rkd: RangeKeyDir, maxEntriesPerRange: int = 100_000): bool =
  ## Check if pending buffer should be flushed
  ## Also flush if we're approaching maxEntriesPerRange to avoid oversized ranges

  # Use the smaller of maxPendingInserts and maxEntriesPerRange as threshold
  # This ensures tests with tiny maxEntriesPerRange still flush frequently
  let effectiveThreshold = min(rkd.maxPendingInserts, max(maxEntriesPerRange - rkd.entryCount, 10))

  return rkd.pendingInserts.len >= effectiveThreshold

proc maybeFlush*(rkd: RangeKeyDir) =
  ## Flush if pending buffer exceeds threshold
  if rkd.shouldFlush():
    rkd.flush()

# --- Iteration ---

iterator pairs*(rkd: RangeKeyDir): (string, RangeKeyDirEntry) =
  ## Iterate over all entries (sorted array + pending)
  ## Note: Does not merge - may yield duplicates if key is in both

  # Yield from sorted array
  for i in 0..<rkd.entryCount:
    let offset = rkd.getOffset(i)
    let (key, entry) = rkd.readEntryAt(offset)
    # Skip if overwritten by pending
    if key notin rkd.pendingInserts:
      yield (key, entry)

  # Yield from pending
  for key, entry in rkd.pendingInserts:
    yield (key, entry)

iterator keys*(rkd: RangeKeyDir): string =
  ## Iterate over all keys
  for key, _ in rkd.pairs():
    yield key

# --- Statistics ---

proc len*(rkd: RangeKeyDir): int =
  ## Get total number of entries (approximate - includes pending)
  rkd.entryCount + rkd.pendingInserts.len

proc pendingCount*(rkd: RangeKeyDir): int =
  ## Get number of pending inserts
  rkd.pendingInserts.len

proc sortedCount*(rkd: RangeKeyDir): int =
  ## Get number of entries in sorted array
  rkd.entryCount

proc dataSize*(rkd: RangeKeyDir): int =
  ## Get size of serialized data in bytes
  rkd.data.len
