## Hint File Implementation for Fast Recovery
##
## Hint files are companion files to data files that contain only key metadata,
## enabling fast recovery without scanning full data files.
##
## Format v3 (current):
## - Header (48 bytes): magic, version, timestamp, entryCount, dataFileId, lastScanPos, dataFileSize, crc32, reserved
## - Entries (variable): keyLen(2) + key + recordPos(8) + valueSize(4) + recordSize(4) = 18 + keyLen bytes
##
## Removed from v2: timestamp (8 bytes), valuePos (8 bytes), deleted (1 byte)
## - valuePos calculated from recordPos + keyLen
## - deleted derived from valueSize == 0
## - timestamp not needed (position ordering in append-only log)
## - fileId from header (same for all entries in a hint file)

import std/[os, times]
import ../bitbarrel/types
import keydir
from crc32 import crc32

const
  HINT_MAGIC* = ['H', 'I', 'N', 'T']
  HINT_VERSION_V1* = 1'u32
  HINT_VERSION_V2* = 2'u32
  HINT_VERSION_V3* = 3'u32
  HINT_VERSION* = HINT_VERSION_V3  # Current version
  HINT_HEADER_SIZE_V1* = 32
  HINT_HEADER_SIZE* = 48  # Version 2+ header size

type
  HintHeader* = object
    magic*: array[4, char]      # "HINT"
    version*: uint32            # Version number
    timestamp*: int64           # Creation timestamp
    entryCount*: uint32         # Number of entries
    dataFileId*: uint32         # Associated data file ID
    lastScanPos*: uint64        # Byte offset where hint stopped scanning (v2+)
    dataFileSize*: uint64       # Data file size at hint creation (v2+)
    crc32*: uint32              # Header checksum
    reserved*: array[8, byte]   # Reserved for future use

  HintEntry* = object
    key*: string                # Key string
    recordPos*: uint64          # Position of record in data file (CRC position)
    valueSize*: uint32          # Size of value (0 = tombstone/deleted)
    recordSize*: uint32         # Total record size

  HintFile* = ref object
    path*: string
    dataFileId*: uint32
    header*: HintHeader
    entries*: seq[HintEntry]

proc calculateHeaderCrc(header: var HintHeader): uint32 =
  ## Calculate CRC32 for header (excluding the crc32 field itself)
  ## For v2: covers first 40 bytes (crc32 is at offset 40)
  var data = newString(40)
  copyMem(addr data[0], addr header, 40)
  result = crc32(data)

proc writeHintFile*(path: string, dataFileId: uint32, entries: seq[HintEntry],
                   dataFileSize: uint64 = 0): bool =
  ## Write a hint file with the given entries
  ## dataFileSize: size of data file at hint creation (for incremental recovery)
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
      lastScanPos: dataFileSize,     # We've scanned to end of file
      dataFileSize: dataFileSize,
      crc32: 0,
      reserved: [0'u8, 0, 0, 0, 0, 0, 0, 0]
    )
    header.crc32 = calculateHeaderCrc(header)

    let headerWritten = file.writeBuffer(addr header, HINT_HEADER_SIZE)
    if headerWritten != HINT_HEADER_SIZE:
      return false

    # Write entries (v3 format: keyLen + key + recordPos + valueSize + recordSize)
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

      # Write valueSize (4 bytes)
      var valueSize = entry.valueSize
      discard file.writeBuffer(addr valueSize, 4)

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
  ## Only supports version 3 format

  result.success = false

  if not fileExists(path):
    return

  try:
    let file = open(path, fmRead)
    defer: file.close()

    # Read header
    var header: HintHeader
    if file.readBuffer(addr header, HINT_HEADER_SIZE) != HINT_HEADER_SIZE:
      return

    # Validate magic
    if header.magic != HINT_MAGIC:
      return

    # Only support v3
    if header.version != HINT_VERSION_V3:
      return  # Old versions not supported

    # Validate CRC (first 40 bytes)
    let storedCrc = header.crc32
    let computedCrc = calculateHeaderCrc(header)
    if storedCrc != computedCrc:
      return

    result.header = header

    # Read entries (v3 format: keyLen + key + recordPos + valueSize + recordSize)
    var entries: seq[HintEntry] = @[]
    for i in 0..<header.entryCount.int:
      var entry: HintEntry

      # Read key length (2 bytes)
      var keyLen: uint16
      if file.readBuffer(addr keyLen, 2) != 2:
        return

      # Read key
      if keyLen > 0:
        entry.key = newString(keyLen.int)
        if file.readBuffer(addr entry.key[0], keyLen.int) != keyLen.int:
          return
      else:
        entry.key = ""

      # Read recordPos (8 bytes)
      if file.readBuffer(addr entry.recordPos, 8) != 8:
        return

      # Read valueSize (4 bytes)
      if file.readBuffer(addr entry.valueSize, 4) != 4:
        return

      # Read recordSize (4 bytes)
      if file.readBuffer(addr entry.recordSize, 4) != 4:
        return

      entries.add(entry)

    result.entries = entries
    result.success = true

  except IOError:
    result.success = false

proc validateHintFile*(path: string): bool =
  ## Validate a hint file without loading all entries
  ## Returns true if the file is valid (v3 format only)

  if not fileExists(path):
    return false

  try:
    let file = open(path, fmRead)
    defer: file.close()

    # Read header
    var header: HintHeader
    if file.readBuffer(addr header, HINT_HEADER_SIZE) != HINT_HEADER_SIZE:
      return false

    # Validate magic
    if header.magic != HINT_MAGIC:
      return false

    # Only support v3
    if header.version != HINT_VERSION_V3:
      return false

    # Validate CRC (first 40 bytes)
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
      recordPos: entry.recordPos,
      fileId: header.dataFileId,  # fileId from header (same for all entries)
      valueSize: entry.valueSize,
      recordSize: entry.recordSize,
      keyLen: entry.key.len.uint16
    )

    # Always add (position ordering in hint file = correct ordering)
    keyDir.add(entry.key, kdEntry)
    inc loaded

  return loaded
