## RangeKeyDir - Fast Serializable Index for bmHugeCritBit
##
## Uses a sorted array format for O(1) deserialization and O(log n) lookups.
## Inserts are buffered and merged on flush to avoid constant rebuilds.

import std/[algorithm, tables, options, strformat]
import ../bitbarrel/types

const
  RANGEKEYDIR_MAGIC* = ['R', 'K', 'D', 'R']
  RANGEKEYDIR_VERSION* = 1'u32
  HEADER_SIZE = 48
  DEFAULT_MAX_PENDING = 1000
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
    # Range bounds
    minKey*: string
    maxKey*: string

    # Sorted array data (serialized blob kept for binary search)
    data*: string               # The serialized blob
    entryCount*: int            # Number of entries in sorted array
    offsetTableStart*: int      # Position of offset table in data
    entriesStart*: int          # Position of entries section in data

    # Insert buffer (checked alongside sorted array)
    pendingInserts*: Table[string, RangeKeyDirEntry]
    maxPendingInserts*: int     # Threshold for auto-flush

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

proc writeInt64(s: var string, val: int64) =
  writeUint64(s, cast[uint64](val))

proc writeString(s: var string, val: string) =
  writeUint16(s, val.len.uint16)
  s.add(val)

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

proc readInt64(data: string, pos: int): int64 =
  cast[int64](readUint64(data, pos))

proc readString(data: string, pos: int): (string, int) =
  let length = readUint16(data, pos).int
  let str = data[pos + 2 ..< pos + 2 + length]
  (str, pos + 2 + length)

# --- RangeKeyDir creation ---

proc newRangeKeyDir*(minKey: string = "", maxKey: string = "",
                     maxPending: int = DEFAULT_MAX_PENDING): RangeKeyDir =
  ## Create a new empty RangeKeyDir
  result = RangeKeyDir(
    minKey: minKey,
    maxKey: maxKey,
    data: "",
    entryCount: 0,
    offsetTableStart: 0,
    entriesStart: 0,
    pendingInserts: initTable[string, RangeKeyDirEntry](),
    maxPendingInserts: maxPending,
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

proc readEntryAt*(rkd: RangeKeyDir, entryOffset: int): RangeKeyDirEntry =
  ## Read a full entry at a given entry offset
  var pos = rkd.entriesStart + entryOffset

  let (key, nextPos) = readString(rkd.data, pos)
  pos = nextPos

  result = RangeKeyDirEntry(
    key: key,
    fileId: readUint32(rkd.data, pos),
    recordPos: readUint64(rkd.data, pos + 4),
    valuePos: readUint64(rkd.data, pos + 12),
    valueSize: readUint32(rkd.data, pos + 20),
    timestamp: readInt64(rkd.data, pos + 24),
    recordSize: readUint32(rkd.data, pos + 32),
    deleted: rkd.data[pos + 36] == '\x01'
  )

# --- Serialization ---

proc serialize*(rkd: RangeKeyDir): string =
  ## Serialize the RangeKeyDir to a binary blob
  ## Format:
  ##   Header (48 bytes)
  ##   Offset table (entryCount * 4 bytes)
  ##   Keys section (minKey + maxKey with length prefixes)
  ##   Entries section (sorted by key)

  # Collect all entries (merged from sorted array + pending)
  var allEntries: seq[tuple[key: string, entry: RangeKeyDirEntry]] = @[]

  # Add entries from existing sorted array
  if rkd.data.len > 0 and rkd.entryCount > 0:
    for i in 0..<rkd.entryCount:
      let offset = rkd.getOffset(i)
      let entry = rkd.readEntryAt(offset)
      # Skip if overwritten by pending
      if entry.key notin rkd.pendingInserts:
        allEntries.add((entry.key, entry))

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

    # Entry format: keyLen(2) + key + fileId(4) + recordPos(8) + valuePos(8) +
    #               valueSize(4) + timestamp(8) + recordSize(4) + deleted(1)
    entriesData.writeString(key)
    entriesData.writeUint32(entry.fileId)
    entriesData.writeUint64(entry.recordPos)
    entriesData.writeUint64(entry.valuePos)
    entriesData.writeUint32(entry.valueSize)
    entriesData.writeInt64(entry.timestamp)
    entriesData.writeUint32(entry.recordSize)
    entriesData.add(if entry.deleted: '\x01' else: '\x00')

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
  # Reserved (20 bytes)
  for i in 0..<20:
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
    raise newException(ValueError, fmt("Unsupported version: {version}"))

  let flags = readUint32(data, 8)
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

  result = RangeKeyDir(
    minKey: minKey,
    maxKey: maxKey,
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
      return some(rkd.readEntryAt(offset))
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
  entry.isSome and not entry.get().deleted

# --- Insert operations ---

proc insert*(rkd: RangeKeyDir, key: string, entry: RangeKeyDirEntry) =
  ## Insert or update an entry
  ## Buffers the insert - call flush() to rebuild sorted array
  rkd.pendingInserts[key] = entry
  rkd.isDirty = true

  # Update bounds
  if rkd.minKey.len == 0 or key < rkd.minKey:
    rkd.minKey = key
  if rkd.maxKey.len == 0 or key > rkd.maxKey:
    rkd.maxKey = key

proc delete*(rkd: RangeKeyDir, key: string) =
  ## Mark a key as deleted
  let existing = rkd.find(key)
  if existing.isSome:
    var entry = existing.get()
    entry.deleted = true
    rkd.insert(key, entry)

proc flush*(rkd: RangeKeyDir) =
  ## Rebuild the sorted array by merging pending inserts
  if rkd.pendingInserts.len == 0:
    return

  # Serialize and deserialize to rebuild
  let serialized = rkd.serialize()
  let rebuilt = deserialize(serialized)

  rkd.data = rebuilt.data
  rkd.entryCount = rebuilt.entryCount
  rkd.offsetTableStart = rebuilt.offsetTableStart
  rkd.entriesStart = rebuilt.entriesStart
  rkd.minKey = rebuilt.minKey
  rkd.maxKey = rebuilt.maxKey
  rkd.pendingInserts.clear()
  rkd.isDirty = false

proc shouldFlush*(rkd: RangeKeyDir): bool =
  ## Check if pending buffer should be flushed
  rkd.pendingInserts.len >= rkd.maxPendingInserts

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
    let entry = rkd.readEntryAt(offset)
    # Skip if overwritten by pending
    if entry.key notin rkd.pendingInserts:
      yield (entry.key, entry)

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
