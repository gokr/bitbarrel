## CritBit Hint File Management
##
## This module handles persistence of CritBitIndex ranges for bmRangedCritBit mode

import std/[os, strformat, streams, tables, times, algorithm]
import ../bitbarrel/types, critbitindex

const
  CRITBIT_HINT_MAGIC* = ['C', 'H', 'N', 'T']  # CritBit Hint
  CRITBIT_HINT_VERSION* = 1'u32
  CRC32_POLYNOMIAL = 0xEDB88320'u32

type
  CritBitHintHeader* = object
    magic*: array[4, char]      # "CHNT"
    version*: uint32
    timestamp*: int64
    entryCount*: uint32
    rangeId*: uint32
    checksum*: uint32
    reserved*: array[4, byte]

  CritBitHintEntry* = object
    key*: string                # Key string
    fileId*: uint32             # Data file ID
    recordPos*: uint64          # Record position in file
    valuePos*: uint64           # Value position in file
    valueSize*: uint32          # Size of value
    timestamp*: int64           # For conflict resolution and TTL
    recordSize*: uint32         # Total record size for merge decisions
    deleted*: bool              # True if this entry is a tombstone

proc crc32(data: pointer, len: int): uint32 {.inline.} =
  ## Simple CRC32 implementation
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

proc saveCritBitHint*(index: var CritBitIndex, rangeId: uint32, filePath: string) =
  ## Save CritBitIndex to a hint file

  var stream = newFileStream(filePath, fmWrite)
  if stream == nil:
    raise newException(IOError, &"Cannot open hint file for writing: {filePath}")

  try:
    # Write header
    var header = CritBitHintHeader(
      magic: CRITBIT_HINT_MAGIC,
      version: CRITBIT_HINT_VERSION,
      timestamp: getTime().toUnix(),
      entryCount: 0'u32,  # Will update later
      rangeId: rangeId,
      checksum: 0,
      reserved: [0.byte, 0.byte, 0.byte, 0.byte]
    )

    # Reserve space for header
    let headerPos = stream.getPosition()
    stream.write(header)

    # Write entries
    var entryCount: uint32 = 0
    var entries: seq[CritBitHintEntry] = @[]

    # Collect all entries from CritBit tree
    for key, value in index.pairs:
      entries.add(CritBitHintEntry(
        key: key,
        fileId: value.fileId,
        recordPos: value.recordPos,
        valuePos: value.valuePos,
        valueSize: value.valueSize,
        timestamp: value.timestamp,
        recordSize: value.recordSize,
        deleted: value.deleted
      ))
      inc(entryCount)

    # Sort entries by key for efficient loading
    entries.sort(proc(a, b: CritBitHintEntry): int = cmp(a.key, b.key))

    # Write entries
    for entry in entries:
      # Write key length and key
      let keyLen = entry.key.len.uint32
      stream.write(keyLen)
      if keyLen > 0:
        stream.write(entry.key)

      # Write value fields
      stream.write(entry.fileId)
      stream.write(entry.recordPos)
      stream.write(entry.valuePos)
      stream.write(entry.valueSize)
      stream.write(entry.timestamp)
      stream.write(entry.recordSize)
      stream.write(entry.deleted.uint8)

    # Update header with final entry count
    header.entryCount = entryCount

    # Calculate checksum from the data we wrote
    # Read back the file data (excluding header checksum field)
    stream.flush()
    stream.setPosition(0)

    # Read all data for checksum calculation
    var allData = newString(stream.getPosition().int)
    stream.setPosition(0)
    let fileSize = getFileSize(filePath).int
    allData = newString(fileSize)
    if fileSize > 0:
      discard stream.readData(addr allData[0], fileSize)

    # Calculate CRC32 over entire file (with checksum field zeroed)
    var tempHeader = header
    tempHeader.checksum = 0
    header.checksum = crc32(addr tempHeader, sizeof(CritBitHintHeader))

    # Rewrite header with correct checksum
    stream.setPosition(0)
    stream.write(header)

  finally:
    stream.close()

proc loadCritBitHint*(filePath: string): tuple[index: CritBitIndex, entryCount: int] =
  ## Load CritBitIndex from a hint file
  ## Returns: (loaded index, number of entries)

  result.index = critbitIndex.init()
  result.entryCount = 0

  if not fileExists(filePath):
    return  # No hint file exists (empty range)

  var stream = newFileStream(filePath, fmRead)
  if stream == nil:
    raise newException(IOError, &"Cannot open hint file for reading: {filePath}")

  try:
    # Read and validate header
    var header: CritBitHintHeader
    discard stream.readData(addr header, sizeof(CritBitHintHeader))

    # Validate magic number
    if header.magic != CRITBIT_HINT_MAGIC:
      raise newException(IOError, &"Invalid hint file magic: {filePath}")

    # Validate version
    if header.version != CRITBIT_HINT_VERSION:
      raise newException(IOError, &"Unsupported hint file version: {header.version} in {filePath}")

    # Read entries
    for i in 0..<header.entryCount:
      # Read key
      var keyLen: uint32
      discard stream.readData(addr keyLen, sizeof(uint32))

      var key = ""
      if keyLen > 0:
        key = newString(keyLen)
        discard stream.readData(addr key[0], keyLen.int)

      # Read value fields
      var fileId: uint32
      var recordPos: uint64
      var valuePos: uint64
      var valueSize: uint32
      var timestamp: int64
      var recordSize: uint32
      var deleted: uint8

      discard stream.readData(addr fileId, sizeof(uint32))
      discard stream.readData(addr recordPos, sizeof(uint64))
      discard stream.readData(addr valuePos, sizeof(uint64))
      discard stream.readData(addr valueSize, sizeof(uint32))
      discard stream.readData(addr timestamp, sizeof(int64))
      discard stream.readData(addr recordSize, sizeof(uint32))
      discard stream.readData(addr deleted, sizeof(uint8))

      # Add to index
      result.index.add(key, KeyDirEntry(
        fileId: fileId,
        recordPos: recordPos,
        valuePos: valuePos,
        valueSize: valueSize,
        timestamp: timestamp,
        recordSize: recordSize,
        deleted: deleted.bool
      ))

      inc(result.entryCount)

    # Verify checksum if saved
    if header.checksum != 0:
      # TODO: Implement checksum verification
      discard

  finally:
    stream.close()