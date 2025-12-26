## Hint File Implementation for Fast Recovery
##
## Hint files are companion files to data files that contain only key metadata,
## enabling fast recovery without scanning full data files.
##
## Format:
## - Header (32 bytes): magic, version, timestamp, entryCount, dataFileId, reserved
## - Entries (variable): keyLen(2) + key + recordPos(8) + valuePos(8) + valueSize(4) + timestamp(8) + recordSize(4) + deleted(1)

import std/[os, times]
import ../bitbarrel/types
import keydir
from crc32 import crc32

const
  HINT_MAGIC* = ['H', 'I', 'N', 'T']
  HINT_VERSION_V1* = 1'u32
  HINT_VERSION_V2* = 2'u32
  HINT_VERSION* = HINT_VERSION_V2  # Current version
  HINT_HEADER_SIZE_V1* = 32
  HINT_HEADER_SIZE* = 48  # Version 2 header size

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
    valuePos*: uint64           # Position of value within record
    valueSize*: uint32          # Size of value
    timestamp*: int64           # Record timestamp
    recordSize*: uint32         # Total record size
    deleted*: bool              # True if this is a tombstone

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

      # Write deleted flag (1 byte)
      var deletedByte: uint8 = if entry.deleted: 1 else: 0
      discard file.writeBuffer(addr deletedByte, 1)

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
  ## Supports both version 1 (32-byte header) and version 2 (48-byte header)

  result.success = false

  if not fileExists(path):
    return

  try:
    let file = open(path, fmRead)
    defer: file.close()

    # Read first 4 bytes to check magic and get version
    var magic: array[4, char]
    if file.readBuffer(addr magic, 4) != 4:
      return

    if magic != HINT_MAGIC:
      return

    # Read version (4 bytes)
    var version: uint32
    if file.readBuffer(addr version, 4) != 4:
      return

    # Seek back to start
    file.setFilePos(0)

    var header: HintHeader

    # Read based on version
    if version == HINT_VERSION_V1:
      # Read v1 header (32 bytes)
      let v1HeaderSize = 32'u32
      var v1Data: array[32, byte]
      if file.readBuffer(addr v1Data[0], v1HeaderSize.int) != v1HeaderSize.int:
        return

      # Parse v1 fields directly into header
      copyMem(addr header.magic, addr v1Data[0], 4)    # magic
      copyMem(addr header.version, addr v1Data[4], 4) # version
      copyMem(addr header.timestamp, addr v1Data[8], 8)  # timestamp
      copyMem(addr header.entryCount, addr v1Data[16], 4)  # entryCount
      copyMem(addr header.dataFileId, addr v1Data[20], 4)  # dataFileId
      copyMem(addr header.crc32, addr v1Data[24], 4)    # crc32 at offset 24 for v1

      # v1 specific: crc32 and reserved are in different positions
      # v1 layout: magic(4) + version(4) + timestamp(8) + entryCount(4) + dataFileId(4) + crc32(4) + reserved(4) = 32
      header.lastScanPos = 0
      header.dataFileSize = 0

      # Validate v1 CRC (only first 28 bytes before crc32)
      var crcData = newString(28)
      copyMem(addr crcData[0], addr v1Data[0], 28)
      let storedCrc = header.crc32
      let computedCrc = crc32(crcData)
      if storedCrc != computedCrc:
        return

    elif version == HINT_VERSION_V2:
      # Read v2 header (48 bytes)
      let v2HeaderSize = HINT_HEADER_SIZE.uint32
      if file.readBuffer(addr header, v2HeaderSize.int) != v2HeaderSize.int:
        return

      # Validate v2 CRC (first 40 bytes)
      let storedCrc = header.crc32
      let computedCrc = calculateHeaderCrc(header)
      if storedCrc != computedCrc:
        return

    else:
      return  # Unknown version

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

      # Read deleted flag (1 byte)
      var deletedByte: uint8
      let deletedRead = file.readBuffer(addr deletedByte, 1)
      if deletedRead != 1:
        return
      entry.deleted = deletedByte != 0

      entries.add(entry)

    result.entries = entries
    result.success = true

  except IOError:
    result.success = false

proc validateHintFile*(path: string): bool =
  ## Validate a hint file without loading all entries
  ## Returns true if the file is valid
  ## Supports both version 1 and version 2 hint files

  if not fileExists(path):
    return false

  try:
    let file = open(path, fmRead)
    defer: file.close()

    # Read first 4 bytes to check magic
    var magic: array[4, char]
    if file.readBuffer(addr magic, 4) != 4:
      return false

    if magic != HINT_MAGIC:
      return false

    # Read version
    var version: uint32
    if file.readBuffer(addr version, 4) != 4:
      return false

    # Seek back to start
    file.setFilePos(0)

    # Validate and read based on version
    if version == HINT_VERSION_V1:
      # Read v1 header (32 bytes)
      var v1Data: array[32, byte]
      if file.readBuffer(addr v1Data[0], 32) != 32:
        return false

      # Validate v1 CRC (first 28 bytes)
      var crcData = newString(28)
      copyMem(addr crcData[0], addr v1Data[0], 28)

      # Read crc32 from offset 24
      var storedCrc: uint32
      copyMem(addr storedCrc, addr v1Data[24], 4)

      let computedCrc = crc32(crcData)
      if storedCrc != computedCrc:
        return false

    elif version == HINT_VERSION_V2:
      # Read v2 header (48 bytes)
      var v2Data: array[48, byte]
      if file.readBuffer(addr v2Data[0], 48) != 48:
        return false

      # Validate v2 CRC (first 40 bytes)
      var crcData = newString(40)
      copyMem(addr crcData[0], addr v2Data[0], 40)

      # Read crc32 from offset 40
      var storedCrc: uint32
      copyMem(addr storedCrc, addr v2Data[40], 4)

      # Calculate CRC of first 40 bytes
      let computedCrc = crc32(crcData)
      if storedCrc != computedCrc:
        return false

    else:
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
      recordSize: entry.recordSize,
      deleted: entry.deleted
    )

    # Only add if newer than existing
    if keyDir.addIfNewer(entry.key, kdEntry):
      inc loaded

  return loaded
