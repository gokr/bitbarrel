## Data file implementation for Bitcask storage model

import std/[os, times, locks]
when defined(posix):
  import std/posix
import ../bitbarrel/types
from record import Record, encode, decode
from ./crc32 import crc32
from writebuffer import WriteBuffer, initWriteBuffer, startWorker, stopWorker, addEntry

when defined(posix):
  type
    RwLock {.importc: "pthread_rwlock_t", header: "<pthread.h>".} = object
    RwLockAttr {.importc: "pthread_rwlockattr_t", header: "<pthread.h>".} = object
  proc pthreadRwlockInit(lk: var RwLock, attr: pointer): cint {.importc: "pthread_rwlock_init", header: "<pthread.h>".}
  proc pthreadRwlockDestroy(lk: var RwLock): cint {.importc: "pthread_rwlock_destroy", header: "<pthread.h>".}
  proc acquireRead*(lk: var RwLock): cint {.importc: "pthread_rwlock_rdlock", header: "<pthread.h>".}
  proc acquireWrite*(lk: var RwLock): cint {.importc: "pthread_rwlock_wrlock", header: "<pthread.h>".}
  proc release*(lk: var RwLock): cint {.importc: "pthread_rwlock_unlock", header: "<pthread.h>".}
  proc initAttr*(attr: var RwLockAttr): cint {.importc: "pthread_rwlockattr_init", header: "<pthread.h>".}
  proc deinitAttr*(attr: var RwLockAttr): cint {.importc: "pthread_rwlockattr_destroy", header: "<pthread.h>".}
  proc setKindPreferWriterNonrecursive*(attr: var RwLockAttr, kind: cint): cint {.
    importc: "pthread_rwlockattr_setkind_np", header: "<pthread.h>".}
  const PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP* = 1

  proc initLock*(lk: var RwLock, attr: ptr RwLockAttr = nil): cint =
    if attr == nil:
      pthreadRwlockInit(lk, nil)
    else:
      pthreadRwlockInit(lk, cast[pointer](attr))

  proc deinitLock*(lk: var RwLock): cint =
    pthreadRwlockDestroy(lk)
else:
  type RwLock = Lock
  proc initRLock(lk: var RwLock) = initLock(lk)
  proc deinitRLock(lk: var RwLock) = deinitLock(lk)
  proc acquireRead*(lk: var RwLock) = acquire(lk)
  proc acquireWrite*(lk: var RwLock) = acquire(lk)
  proc release*(lk: var RwLock) = release(lk)

template withReadLock*(lock: var RwLock, body: untyped) =
  discard acquireRead(lock)
  try:
    body
  finally:
    discard release(lock)

template withWriteLock*(lock: var RwLock, body: untyped) =
  discard acquireWrite(lock)
  try:
    body
  finally:
    discard release(lock)

type
  DataFile* = object
    file*: File
    path*: string
    fileId*: uint32
    size*: uint64
    lock*: RwLock  # Changed from Lock to RwLock for concurrent reads
    writeBuffer*: ptr WriteBuffer
    syncMode*: SyncMode
    shouldFsync*: bool
    compressionConfig*: ptr CompressionConfig
    validateCrc*: bool

  RecordInfo* = object
    recordPos*: uint64
    valueSize*: uint32
    recordSize*: uint32
    keyLen*: uint16

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
    # Validate existing file header
    file.setFilePos(0)

    var header: FileHeader
    let bytesRead = file.readBuffer(addr header, HEADER_SIZE)
    if bytesRead != HEADER_SIZE:
      raise newException(IOError, "Failed to read file header")

    # Validate header
    let expectedMagic = ['B', 'C', 'K', 'S']
    if header.magic != expectedMagic:
      raise newException(IOError, "Invalid file header magic number")

    if header.version != VERSION:
      raise newException(IOError, "Unsupported file version: " & $header.version)

    # Seek to end for appending
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
  when defined(posix):
    var attr: RwLockAttr
    discard initAttr(attr)
    discard setKindPreferWriterNonrecursive(attr, PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP)
    discard initLock(result.lock, addr attr)
    discard deinitAttr(attr)
  else:
    initRLock(result.lock)

proc open*(path: string, fileId: uint32, syncMode: SyncMode, shouldFsync: bool, bufferSize: int, validateCrc: bool = true, compressionConfig: ptr CompressionConfig = nil): DataFile =
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
    # Validate existing file header
    file.setFilePos(0)

    var header: FileHeader
    let bytesRead = file.readBuffer(addr header, HEADER_SIZE)
    if bytesRead != HEADER_SIZE:
      raise newException(IOError, "Failed to read file header")

    # Validate header
    let expectedMagic = ['B', 'C', 'K', 'S']
    if header.magic != expectedMagic:
      raise newException(IOError, "Invalid file header magic number")

    if header.version != VERSION:
      raise newException(IOError, "Unsupported file version: " & $header.version)

    # Seek to end for appending
    file.setFilePos(0, fspEnd)

  let size = getFileSize(path).uint64

  result = DataFile(
    file: file,
    path: path,
    fileId: fileId,
    size: size,
    syncMode: syncMode,
    shouldFsync: shouldFsync,
    compressionConfig: compressionConfig,
    validateCrc: validateCrc
  )
  when defined(posix):
    var attr: RwLockAttr
    discard initAttr(attr)
    discard setKindPreferWriterNonrecursive(attr, PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP)
    discard initLock(result.lock, addr attr)
    discard deinitAttr(attr)
  else:
    initRLock(result.lock)

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
  # Flush file to disk before closing
  df.file.flushFile()
  when defined(posix):
    if df.shouldFsync:
      discard fsync(df.file.getFileHandle())
  when defined(posix):
    discard deinitLock(df.lock)
  else:
    deinitRLock(df.lock)
  df.file.close()

proc readHeader*(df: var DataFile): FileHeader =
  ## Read the file header (uses read lock for concurrent reads)
  withReadLock(df.lock):
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
    withWriteLock(df.lock):
      let recordPos = df.size
      let recordDataPos = recordPos + 4  # After CRC32

      recordInfo = RecordInfo(
        recordPos: recordDataPos,
        valueSize: value.len.uint32,
        recordSize: (4 + encoded.len).uint32,
        keyLen: key.len.uint16
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

    withWriteLock(df.lock):
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

      # Calculate record position (after CRC32)
      let recordDataPos = recordPos + 4  # After CRC32

      result = RecordInfo(
        recordPos: recordDataPos,
        valueSize: value.len.uint32,
        recordSize: (4 + encoded.len).uint32,
        keyLen: key.len.uint16
      )

proc readRecord*(df: var DataFile, recordInfo: RecordInfo): (string, string, int64) =
  ## Read a record using the recorded position information (thread-safe, uses read lock for concurrent reads)
  var storedCrc: uint32
  var recordData: string

  withReadLock(df.lock):
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

  # Skip flags (1 byte) and algorithm (1 byte)
  var flags: uint8
  var algorithm: uint8
  discard readFile.readBuffer(addr flags, 1)
  discard readFile.readBuffer(addr algorithm, 1)

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