## Hint File Implementation for Fast Recovery
##
## Hint files are companion files to data files that contain only key metadata,
## enabling fast recovery without scanning full data files.
##
## Format:
## - Header (32 bytes): magic, version, timestamp, entryCount, dataFileId, reserved
## - Entries (variable): keyLen(2) + key + recordPos(8) + valuePos(8) + valueSize(4) + timestamp(8) + recordSize(4)

import std/[os, times, strformat]
import ../kvs/types
import keydir
from crc32 import crc32

const
  HINT_MAGIC* = ['H', 'I', 'N', 'T']
  HINT_VERSION* = 1'u32
  HINT_HEADER_SIZE* = 32

type
  HintHeader* = object
    magic*: array[4, char]      # "HINT"
    version*: uint32            # Version number
    timestamp*: int64           # Creation timestamp
    entryCount*: uint32         # Number of entries
    dataFileId*: uint32         # Associated data file ID
    crc32*: uint32              # Header checksum
    reserved*: array[4, byte]   # Reserved for future use

  HintEntry* = object
    key*: string                # Key string
    recordPos*: uint64          # Position of record in data file (CRC position)
    valuePos*: uint64           # Position of value within record
    valueSize*: uint32          # Size of value
    timestamp*: int64           # Record timestamp
    recordSize*: uint32         # Total record size

  HintFile* = ref object
    path*: string
    dataFileId*: uint32
    header*: HintHeader
    entries*: seq[HintEntry]

proc calculateHeaderCrc(header: var HintHeader): uint32 =
  ## Calculate CRC32 for header (excluding the crc32 field itself)
  var tempHeader = header
  tempHeader.crc32 = 0
  # Convert to string for crc32 function
  var data = newString(HINT_HEADER_SIZE)
  copyMem(addr data[0], addr tempHeader, HINT_HEADER_SIZE)
  result = crc32(data)

proc writeHintFile*(path: string, dataFileId: uint32, entries: seq[HintEntry]): bool =
  ## Write a hint file with the given entries
  ## Returns true on success, false on failure

  let tempPath = path & ".tmp"

  try:
    let file = open(tempPath, fmWrite)
    defer: file.close()

    # Create and write header
    var header = HintHeader(
      magic: HINT_MAGIC,
      version: HINT_VERSION,
      timestamp: getTime().toUnix(),
      entryCount: entries.len.uint32,
      dataFileId: dataFileId,
      crc32: 0,
      reserved: [0'u8, 0, 0, 0]
    )
    header.crc32 = calculateHeaderCrc(header)

    let headerWritten = file.writeBuffer(addr header, HINT_HEADER_SIZE)
    if headerWritten != HINT_HEADER_SIZE:
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
    # Clean up temp file on error
    if fileExists(tempPath):
      removeFile(tempPath)
    return false

proc readHintFile*(path: string): tuple[header: HintHeader, entries: seq[HintEntry], success: bool] =
  ## Read a hint file and return its contents
  ## Returns (header, entries, success)

  result.success = false

  if not fileExists(path):
    return

  try:
    let file = open(path, fmRead)
    defer: file.close()

    # Read header
    var header: HintHeader
    let headerRead = file.readBuffer(addr header, HINT_HEADER_SIZE)
    if headerRead != HINT_HEADER_SIZE:
      return

    # Validate magic
    if header.magic != HINT_MAGIC:
      return

    # Validate version
    if header.version != HINT_VERSION:
      return

    # Validate CRC
    let storedCrc = header.crc32
    let computedCrc = calculateHeaderCrc(header)
    if storedCrc != computedCrc:
      return

    result.header = header

    # Read entries
    var entries: seq[HintEntry] = @[]
    for i in 0..<header.entryCount.int:
      var entry: HintEntry

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

proc validateHintFile*(path: string): bool =
  ## Validate a hint file without loading all entries
  ## Returns true if the file is valid

  if not fileExists(path):
    return false

  try:
    let file = open(path, fmRead)
    defer: file.close()

    # Read header
    var header: HintHeader
    let headerRead = file.readBuffer(addr header, HINT_HEADER_SIZE)
    if headerRead != HINT_HEADER_SIZE:
      return false

    # Validate magic
    if header.magic != HINT_MAGIC:
      return false

    # Validate version
    if header.version != HINT_VERSION:
      return false

    # Validate CRC
    let storedCrc = header.crc32
    let computedCrc = calculateHeaderCrc(header)
    if storedCrc != computedCrc:
      return false

    return true

  except IOError:
    return false

proc getHintPath*(dataPath: string): string =
  ## Get the hint file path for a data file path
  ## e.g., "000001.data" -> "000001.hint"
  result = dataPath.changeFileExt("hint")

proc hintFileExists*(dataPath: string): bool =
  ## Check if a hint file exists for the given data file
  result = fileExists(getHintPath(dataPath))

proc loadKeyDirFromHint*(path: string, keyDir: var KeyDir): int =
  ## Load KeyDir entries from a hint file
  ## Returns number of entries loaded, or -1 on error

  let (header, entries, success) = readHintFile(path)
  if not success:
    return -1

  var loaded = 0
  for entry in entries:
    let kdEntry = KeyDirEntry(
      fileId: header.dataFileId,
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
