## Data file implementation for Bitcask storage model

import std/[os, times, locks, strformat]
when defined(posix):
  import std/posix
import ../bitbarrel/types
from record import Record, encode, decode
from ./crc32 import crc32
from writebuffer import WriteBuffer, initWriteBuffer, startWorker, stopWorker, addEntry

type
  DataFile* = object
    file*: File
    path*: string
    fileId*: uint32
    size*: uint64
    lock*: Lock
    writeBuffer*: ptr WriteBuffer  # Optional write buffer
    syncMode*: SyncMode          # Sync strategy
    shouldFsync*: bool           # Whether to call fsync
    compressionConfig*: ptr CompressionConfig  # Compression configuration
    validateCrc*: bool           # Validate CRC32 on reads (default: true)

  RecordInfo* = object
    recordPos*: uint64   # Position of the record (after CRC32)
    valuePos*: uint64    # Position of value within file
    valueSize*: uint32   # Size of value
    recordSize*: uint32  # Total record size

proc open*(path: string, fileId: uint32): DataFile =
  ## Open a data file, creating it if it doesn't exist
  ## Uses immediate sync mode (no write buffering)

  # Check if file exists before opening to decide mode
  let fileExists = fileExists(path) and getFileSize(path) > 0

  let file = if fileExists:
    open(path, fmReadWriteExisting)  # Don't truncate existing file
  else:
    open(path, fmReadWrite)  # Create new file

  # If file is empty, write header
  if not fileExists:
    var header = FileHeader(
      magic: ['B', 'C', 'K', 'S'],
      version: VERSION,
      created: getTime().toUnix(),
      fileSize: HEADER_SIZE.uint64
    )
    let bytesWritten = file.writeBuffer(addr header, HEADER_SIZE)
    if bytesWritten != HEADER_SIZE:
      raise newException(IOError, "Failed to write file header")
    file.flushFile()
    when defined(posix):
      discard fsync(file.getFileHandle())
    file.setFilePos(0, fspEnd)
  else:
    file.setFilePos(0, fspEnd)

  let size = getFileSize(path).uint64

  result = DataFile(
    file: file,
    path: path,
    fileId: fileId,
    size: size,
    syncMode: syncImmediate,
    shouldFsync: true,
    compressionConfig: nil,
    validateCrc: true
  )
  initLock(result.lock)

proc open*(path: string, fileId: uint32, syncMode: SyncMode, shouldFsync: bool, bufferSize: int, validateCrc: bool = true): DataFile =
  ## Open a data file with configurable sync strategy

  # Check if file exists before opening to decide mode
  let fileExistsNow = fileExists(path) and getFileSize(path) > 0

  let file = if fileExistsNow:
    open(path, fmReadWriteExisting)  # Don't truncate existing file
  else:
    open(path, fmReadWrite)  # Create new file

  # If file is empty, write header
  if not fileExistsNow:
    var header = FileHeader(
      magic: ['B', 'C', 'K', 'S'],
      version: VERSION,
      created: getTime().toUnix(),
      fileSize: HEADER_SIZE.uint64
    )
    let bytesWritten = file.writeBuffer(addr header, HEADER_SIZE)
    if bytesWritten != HEADER_SIZE:
      raise newException(IOError, "Failed to write file header")
    file.flushFile()
    when defined(posix):
      discard fsync(file.getFileHandle())
    file.setFilePos(0, fspEnd)
  else:
    file.setFilePos(0, fspEnd)

  let size = getFileSize(path).uint64

  result = DataFile(
    file: file,
    path: path,
    fileId: fileId,
    size: size,
    syncMode: syncMode,
    shouldFsync: shouldFsync,
    compressionConfig: nil,
    validateCrc: validateCrc
  )
  initLock(result.lock)

  # Create write buffer if not immediate mode
  if syncMode != syncImmediate and bufferSize > 0:
    result.writeBuffer = create(WriteBuffer)
    result.writeBuffer[] = initWriteBuffer(
      maxSize = bufferSize,
      syncMode = syncMode,
      batchSize = 1000,
      flushIntervalMs = 100
    )
    startWorker(result.writeBuffer[])

proc close*(df: var DataFile) =
  ## Close the data file
  if df.writeBuffer != nil:
    stopWorker(df.writeBuffer[])
    dealloc(df.writeBuffer)
    df.writeBuffer = nil
  deinitLock(df.lock)
  df.file.close()

proc readHeader*(df: var DataFile): FileHeader =
  ## Read the file header
  withLock(df.lock):
    let oldPos = df.file.getFilePos()
    df.file.setFilePos(0)

    var header: FileHeader
    let bytesRead = df.file.readBuffer(addr header, HEADER_SIZE)

    df.file.setFilePos(oldPos)

    if bytesRead != HEADER_SIZE:
      raise newException(IOError, "Failed to read file header")

    result = header

proc appendRecord*(df: var DataFile, key: string, value: string, timestamp: int64): RecordInfo =
  ## Append a record to the data file (thread-safe)

  # If we have a write buffer, use it
  if df.writeBuffer != nil:
    let record = Record(key: key, value: value, timestamp: timestamp)
    let encoded = record.encode(df.compressionConfig)
    var crcVal = crc32(encoded)

    # Use a callback-based approach to get RecordInfo after writing
    var recordInfo: RecordInfo

    # Write and update size atomically
    withLock(df.lock):
      let recordPos = df.size
      let recordDataPos = recordPos + 4  # After CRC32
      # New format: timestamp:8 + keyLen:4 + key + valLen:4 + flags:1 + algorithm:1
      let valuePos = recordDataPos + 8 + 4 + key.len.uint64 + 4 + 1 + 1

      recordInfo = RecordInfo(
        recordPos: recordDataPos,
        valuePos: valuePos,
        valueSize: value.len.uint32,
        recordSize: (4 + encoded.len).uint32
      )

      # Write CRC32
      let crcBufWritten = df.file.writeBuffer(addr crcVal, 4)
      if crcBufWritten != 4:
        raise newException(IOError, "Failed to write CRC32")

      # Write encoded record
      let encBufWritten = df.file.writeBuffer(encoded.cstring, encoded.len)
      if encBufWritten != encoded.len:
        raise newException(IOError, "Failed to write record")

      # Update size AFTER writing (consistent with direct write path)
      df.size = df.size + 4.uint64 + encoded.len.uint64

    df.file.flushFile()
    if df.shouldFsync:
      when defined(posix):
        discard fsync(df.file.getFileHandle())

    # Track in write buffer for stats (even if writing immediately)
    discard df.writeBuffer[].addEntry(key, value, timestamp)

    result = recordInfo
  else:
    # Immediate write (original behavior)
    let record = Record(
      key: key,
      value: value,
      timestamp: timestamp
    )

    # Encode outside lock for better concurrency
    let encoded = record.encode(df.compressionConfig)
    var crcVal = crc32(encoded)

    withLock(df.lock):
      let recordPos = df.size

      # Write CRC32 (4 bytes)
      let crcWritten = df.file.writeBuffer(addr crcVal, 4)
      if crcWritten != 4:
        raise newException(IOError, "Failed to write CRC32")

      # Write encoded record (variable length)
      let encWritten = df.file.writeBuffer(encoded.cstring, encoded.len)
      if encWritten != encoded.len:
        raise newException(IOError, "Failed to write record")

      # Update file size
      df.size = df.size + 4.uint64 + encoded.len.uint64
      df.file.flushFile()

      # Ensure data is synced to disk for durability
      if df.shouldFsync:
        when defined(posix):
          discard fsync(df.file.getFileHandle())

      # Calculate where the actual value starts (new format includes flags and algorithm bytes)
      let recordDataPos = recordPos + 4  # After CRC32
      # New format: timestamp:8 + keyLen:4 + key + valLen:4 + flags:1 + algorithm:1
      let valuePos = recordDataPos + 8 + 4 + key.len.uint64 + 4 + 1 + 1

      result = RecordInfo(
        recordPos: recordDataPos,
        valuePos: valuePos,
        valueSize: value.len.uint32,
        recordSize: (4 + encoded.len).uint32
      )

proc readRecord*(df: var DataFile, recordInfo: RecordInfo): (string, string, int64) =
  ## Read a record using the recorded position information (thread-safe)
  var storedCrc: uint32
  var recordData: string

  withLock(df.lock):
    let oldPos = df.file.getFilePos()
    df.file.setFilePos(recordInfo.recordPos.int - 4)  # Position of CRC32

    # Read CRC32 first
    let crcBytesRead = df.file.readBuffer(addr storedCrc, 4)
    if crcBytesRead != 4:
      raise newException(IOError, "Failed to read CRC32")

    # Read the record data
    let recordDataLen = recordInfo.recordSize.int - 4  # Subtract CRC32
    recordData = newString(recordDataLen)
    let bytesRead = df.file.readBuffer(addr recordData[0], recordDataLen)

    if bytesRead != recordDataLen:
      raise newException(IOError, "Failed to read record data")

    # Restore file position
    df.file.setFilePos(oldPos)

  # Verify CRC32 and decode outside lock for better concurrency
  if df.validateCrc:
    let computedCrc = crc32(recordData)
    if storedCrc != computedCrc:
      raise newException(IOError, "CRC32 mismatch: data corruption detected")

  # Decode the record
  let record = decode(recordData)
  result = (record.key, record.value, record.timestamp)

proc readRecordAt*(df: var DataFile, offset: uint64): tuple[key: string, value: string, timestamp: int64, recordSize: uint32] =
  ## Read a record at a specific file offset (for merge/scan operations)
  ## offset should be the position of the CRC32 (start of record)

  # Open file in read mode for reliable seeking
  let readFile = open(df.path, fmRead)
  defer: readFile.close()

  readFile.setFilePos(offset.int64, fspSet)

  var storedCrc: uint32
  var recordData: string

  # Read CRC32 first (4 bytes)
  let crcBytesRead = readFile.readBuffer(addr storedCrc, 4)
  if crcBytesRead != 4:
    raise newException(IOError, "Failed to read CRC32 at offset " & $offset)

  # Read timestamp (8 bytes)
  var timestamp: int64
  let tsBytesRead = readFile.readBuffer(addr timestamp, 8)
  if tsBytesRead != 8:
    raise newException(IOError, "Failed to read timestamp")

  # Read key length (4 bytes)
  var keyLen: uint32
  let keyLenRead = readFile.readBuffer(addr keyLen, 4)
  if keyLenRead != 4:
    raise newException(IOError, "Failed to read key length")

  # Read key
  var key = newString(keyLen.int)
  if keyLen > 0:
    let keyRead = readFile.readBuffer(addr key[0], keyLen.int)
    if keyRead != keyLen.int:
      raise newException(IOError, "Failed to read key")

  # Read value length (4 bytes)
  var valueLen: uint32
  let valueLenRead = readFile.readBuffer(addr valueLen, 4)
  if valueLenRead != 4:
    raise newException(IOError, "Failed to read value length")

  # Read value
  var value = newString(valueLen.int)
  if valueLen > 0:
    let valueRead = readFile.readBuffer(addr value[0], valueLen.int)
    if valueRead != valueLen.int:
      raise newException(IOError, "Failed to read value")

  # Calculate total record size: CRC(4) + timestamp(8) + keyLen(4) + key + valueLen(4) + flags(1) + algorithm(1) + value
  let totalRecordSize = (4 + 8 + 4 + keyLen.int + 4 + 1 + 1 + valueLen.int).uint32

  # Re-read the full record data for CRC verification
  readFile.setFilePos(offset.int64 + 4, fspSet)  # Skip CRC32
  let recordDataLen = totalRecordSize.int - 4
  recordData = newString(recordDataLen)
  let bytesRead = readFile.readBuffer(addr recordData[0], recordDataLen)
  if bytesRead != recordDataLen:
    raise newException(IOError, "Failed to read full record data")

  # Verify CRC32 (only if validation is enabled)
  if df.validateCrc:
    let computedCrc = crc32(recordData)
    if storedCrc != computedCrc:
      raise newException(IOError, "CRC32 mismatch at offset " & $offset)

  result = (key, value, timestamp, totalRecordSize)