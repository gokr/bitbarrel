## Range Hint File - Per-range KeyDir persistence for bmRanged mode
##
## Similar to hintfile.nim but tailored for individual range partitions.
## Each range has its own hint file for fast loading/unloading.
##
## Format:
## - Header (32 bytes): magic, version, timestamp, entryCount, rangeId, checksum
## - Entries (variable): keyLen(2) + key + recordPos(8) + valuePos(8) + valueSize(4) + timestamp(8) + recordSize(4)

import std/[os, times]
import ../bitbarrel/types
import keydir
import crc32

const
  RANGE_HINT_MAGIC* = ['R', 'H', 'N', 'T']
  RANGE_HINT_VERSION* = 1'u32
  RANGE_HINT_HEADER_SIZE* = 32

type
  RangeHintHeader* = object
    magic*: array[4, char]      # "RHNT"
    version*: uint32            # Version number
    timestamp*: int64           # Creation timestamp
    entryCount*: uint32         # Number of entries
    rangeId*: RangeId           # Associated range ID
    checksum*: uint32           # Header checksum
    reserved*: array[4, byte]   # Reserved for future use

  RangeHintEntry* = object
    key*: string                # Key string
    recordPos*: uint64          # Position of record in data file
    valuePos*: uint64           # Position of value within record
    valueSize*: uint32          # Size of value
    timestamp*: int64           # Record timestamp
    recordSize*: uint32         # Total record size

proc calculateHeaderChecksum(header: var RangeHintHeader): uint32 =
  ## Calculate checksum for header (excluding checksum field)
  var tempHeader = header
  tempHeader.checksum = 0
  var data = newString(RANGE_HINT_HEADER_SIZE)
  copyMem(addr data[0], addr tempHeader, RANGE_HINT_HEADER_SIZE)
  result = crc32(data)

proc writeRangeHint*(path: string, rangeId: RangeId, entries: seq[RangeHintEntry]): bool =
  ## Write a range hint file with the given entries
  ## Returns true on success

  let tempPath = path & ".tmp"

  try:
    let file = open(tempPath, fmWrite)
    defer: file.close()

    # Create and write header
    var header = RangeHintHeader(
      magic: RANGE_HINT_MAGIC,
      version: RANGE_HINT_VERSION,
      timestamp: getTime().toUnix(),
      entryCount: entries.len.uint32,
      rangeId: rangeId,
      checksum: 0,
      reserved: [0'u8, 0, 0, 0]
    )
    header.checksum = calculateHeaderChecksum(header)

    let headerWritten = file.writeBuffer(addr header, RANGE_HINT_HEADER_SIZE)
    if headerWritten != RANGE_HINT_HEADER_SIZE:
      return false

    # Write entries
    for entry in entries:
      # Write key length (2 bytes)
      var keyLen = entry.key.len.uint16
      discard file.writeBuffer(addr keyLen, 2)

      # Write key
      if entry.key.len > 0:
        discard file.writeBuffer(unsafeAddr entry.key[0], entry.key.len)

      # Write recordPos (8 bytes)
      var recordPos = entry.recordPos
      discard file.writeBuffer(addr recordPos, 8)

      # Write valuePos (8 bytes)
      var valuePos = entry.valuePos
      discard file.writeBuffer(addr valuePos, 8)

      # Write valueSize (4 bytes)
      var valueSize = entry.valueSize
      discard file.writeBuffer(addr valueSize, 4)

      # Write timestamp (8 bytes)
      var timestamp = entry.timestamp
      discard file.writeBuffer(addr timestamp, 8)

      # Write recordSize (4 bytes)
      var recordSize = entry.recordSize
      discard file.writeBuffer(addr recordSize, 4)

    file.flushFile()

    # Atomic rename
    moveFile(tempPath, path)
    return true

  except IOError, OSError:
    if fileExists(tempPath):
      removeFile(tempPath)
    return false

proc readRangeHint*(path: string): tuple[header: RangeHintHeader, entries: seq[RangeHintEntry], success: bool] =
  ## Read a range hint file and return its contents
  ## Returns (header, entries, success)

  result.success = false

  if not fileExists(path):
    return

  try:
    let file = open(path, fmRead)
    defer: file.close()

    # Read header
    var header: RangeHintHeader
    let headerRead = file.readBuffer(addr header, RANGE_HINT_HEADER_SIZE)
    if headerRead != RANGE_HINT_HEADER_SIZE:
      return

    # Validate magic
    if header.magic != RANGE_HINT_MAGIC:
      return

    # Validate version
    if header.version != RANGE_HINT_VERSION:
      return

    # Validate checksum
    let storedChecksum = header.checksum
    let computedChecksum = calculateHeaderChecksum(header)
    if storedChecksum != computedChecksum:
      return

    result.header = header

    # Read entries
    var entries: seq[RangeHintEntry] = @[]
    for i in 0..<header.entryCount.int:
      var entry: RangeHintEntry

      # Read key length (2 bytes)
      var keyLen: uint16
      let keyLenRead = file.readBuffer(addr keyLen, 2)
      if keyLenRead != 2:
        return

      # Read key
      if keyLen > 0:
        entry.key = newString(keyLen.int)
        let keyRead = file.readBuffer(addr entry.key[0], keyLen.int)
        if keyRead != keyLen.int:
          return
      else:
        entry.key = ""

      # Read recordPos (8 bytes)
      let recordPosRead = file.readBuffer(addr entry.recordPos, 8)
      if recordPosRead != 8:
        return

      # Read valuePos (8 bytes)
      let valuePosRead = file.readBuffer(addr entry.valuePos, 8)
      if valuePosRead != 8:
        return

      # Read valueSize (4 bytes)
      let valueSizeRead = file.readBuffer(addr entry.valueSize, 4)
      if valueSizeRead != 4:
        return

      # Read timestamp (8 bytes)
      let timestampRead = file.readBuffer(addr entry.timestamp, 8)
      if timestampRead != 8:
        return

      # Read recordSize (4 bytes)
      let recordSizeRead = file.readBuffer(addr entry.recordSize, 4)
      if recordSizeRead != 4:
        return

      entries.add(entry)

    result.entries = entries
    result.success = true

  except IOError:
    result.success = false

proc validateRangeHint*(path: string): bool =
  ## Validate a range hint file without loading all entries
  ## Returns true if the file is valid

  if not fileExists(path):
    return false

  try:
    let file = open(path, fmRead)
    defer: file.close()

    # Read header
    var header: RangeHintHeader
    let headerRead = file.readBuffer(addr header, RANGE_HINT_HEADER_SIZE)
    if headerRead != RANGE_HINT_HEADER_SIZE:
      return false

    # Validate magic
    if header.magic != RANGE_HINT_MAGIC:
      return false

    # Validate version
    if header.version != RANGE_HINT_VERSION:
      return false

    # Validate checksum
    let storedChecksum = header.checksum
    let computedChecksum = calculateHeaderChecksum(header)
    if storedChecksum != computedChecksum:
      return false

    return true

  except IOError:
    return false

proc loadKeyDirFromRangeHint*(path: string, keyDir: var KeyDir): int =
  ## Load KeyDir entries from a range hint file
  ## Returns number of entries loaded, or -1 on error

  let (_, entries, success) = readRangeHint(path)
  if not success:
    return -1

  var loaded = 0
  for entry in entries:
    let kdEntry = KeyDirEntry(
      fileId: 0,  # Will be set by caller if needed
      recordPos: entry.recordPos,
      valuePos: entry.valuePos,
      valueSize: entry.valueSize,
      timestamp: entry.timestamp,
      recordSize: entry.recordSize
    )

    # Only add if newer than existing
    if keyDir.addIfNewer(entry.key, kdEntry):
      inc loaded

  return loaded

proc saveKeyDirToRangeHint*(path: string, rangeId: RangeId, keyDir: var KeyDir): bool =
  ## Save a KeyDir to a range hint file
  ## Returns true on success

  var entries: seq[RangeHintEntry] = @[]

  for key, entry in keyDir.pairs():
    entries.add(RangeHintEntry(
      key: key,
      recordPos: entry.recordPos,
      valuePos: entry.valuePos,
      valueSize: entry.valueSize,
      timestamp: entry.timestamp,
      recordSize: entry.recordSize
    ))

  return writeRangeHint(path, rangeId, entries)

proc rangeHintExists*(path: string): bool =
  ## Check if a range hint file exists
  result = fileExists(path)

proc deleteRangeHint*(path: string): bool =
  ## Delete a range hint file
  try:
    if fileExists(path):
      removeFile(path)
    return true
  except OSError:
    return false
