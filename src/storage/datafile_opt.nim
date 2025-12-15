## Optimized Data File Implementation with Group Commit
##
## Provides configurable durability vs performance trade-offs

import std/[os, times, locks]
when defined(posix):
  import std/posix except Time
import ../bitbarrel/types
from record import crc32, Record, encode, decode
from writebuffer import WriteBuffer, startWorker, stopWorker

type
  DataFileOpt* = object
    file*: File
    path*: string
    fileId*: uint32
    size*: uint64
    lock*: Lock
    writeBuffer*: ptr WriteBuffer
    syncMode*: SyncMode
    shouldFsync*: bool

    # Group commit settings
    groupCommitEnabled*: bool
    groupCommitSize*: int
    groupCommitInterval*: Duration  # Time-based group commit
    pendingWrites*: int
    lastSync*: Time
    forceSync*: bool  # Force immediate sync (for critical data)

proc open*(path: string, fileId: uint32): DataFileOpt =
  ## Open with default safe settings (fsync every write)
  open(path, fileId, syncImmediate, true, 0)

proc open*(path: string, fileId: uint32, syncMode: SyncMode, shouldFsync: bool, bufferSize: int): DataFileOpt =
  ## Open a data file with configurable sync strategy
  let file = open(path, fmReadWrite)

  # If file is empty, write header
  if getFileSize(path) == 0:
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

  result = DataFileOpt(
    file: file,
    path: path,
    fileId: fileId,
    size: size,
    syncMode: syncMode,
    shouldFsync: shouldFsync,
    writeBuffer: nil,
    groupCommitEnabled: false,
    groupCommitSize: 1000,  # Default batch size
    groupCommitInterval: initDuration(milliseconds = 100),
    pendingWrites: 0,
    lastSync: getTime(),
    forceSync: false
  )
  initLock(result.lock)

  # Create write buffer if not immediate mode
  if syncMode != syncImmediate and bufferSize > 0:
    result.writeBuffer = create(WriteBuffer)
    result.writeBuffer[] = initWriteBuffer(
      maxSize = bufferSize,
      syncMode = syncMode,
      batchSize = result.groupCommitSize,
      flushIntervalMs = result.groupCommitInterval.inMilliseconds,
    )
    startWorker(result.writeBuffer[])

proc openWithGroupCommit*(path: string, fileId: uint32,
                         groupSize: int = 1000,
                         intervalMs: int = 100): DataFileOpt =
  ## Open data file with group commit enabled for high performance
  result = open(path, fileId, syncBatched, true, groupSize * 100)  # Large buffer
  result.groupCommitEnabled = true
  result.groupCommitSize = groupSize
  result.groupCommitInterval = initDuration(milliseconds = intervalMs)

proc close*(df: var DataFileOpt) =
  ## Close the data file
  # Ensure final sync if using group commit
  if df.groupCommitEnabled and df.pendingWrites > 0:
    withLock(df.lock):
      df.file.flushFile()
      when defined(posix):
        discard fsync(df.file.getFileHandle())
      df.pendingWrites = 0

  if df.writeBuffer != nil:
    stopWorker(df.writeBuffer[])
    dealloc(df.writeBuffer)
    df.writeBuffer = nil
  deinitLock(df.lock)
  df.file.close()

proc performGroupSync(df: var DataFileOpt) =
  ## Perform synchronization for group commit
  if not df.groupCommitEnabled:
    return

  let now = getTime()
  let shouldSync = df.pendingWrites >= df.groupCommitSize or
                   (now - df.lastSync) >= df.groupCommitInterval or
                   df.forceSync

  if shouldSync and df.pendingWrites > 0:
    df.file.flushFile()
    if df.shouldFsync:
      when defined(posix):
        discard fsync(df.file.getFileHandle())
    df.pendingWrites = 0
    df.lastSync = now
    df.forceSync = false

proc appendRecordOpt*(df: var DataFileOpt, key: string, value: string,
                      timestamp: int64, forceSync: bool = false): RecordInfo =
  ## Append a record with optional force sync for critical data

  if df.writeBuffer != nil:
    # Use write buffer for buffered writes
    let record = Record(key: key, value: value, timestamp: timestamp)
    let encoded = record.encode()
    let crcVal = crc32(encoded)

    withLock(df.lock):
      let recordPos = df.size
      let recordDataPos = recordPos + 4
      let valuePos = recordDataPos + 8 + 4 + key.len.uint64

      df.size = df.size + 4.uint64 + encoded.len.uint64

      result = RecordInfo(
        recordPos: recordDataPos,
        valuePos: valuePos,
        valueSize: value.len.uint32,
        recordSize: (4 + encoded.len).uint32
      )

    # Write immediately for now (write buffer needs improvement)
    withLock(df.lock):
      let crcWritten = df.file.writeBuffer(addr crcVal, 4)
      if crcWritten != 4:
        raise newException(IOError, "Failed to write CRC32")

      let encWritten = df.file.writeBuffer(encoded.cstring, encoded.len)
      if encWritten != encoded.len:
        raise newException(IOError, "Failed to write record")

      if df.groupCommitEnabled:
        df.pendingWrites += 1
        if forceSync:
          df.forceSync = true
        performGroupSync(df)
      else:
        df.file.flushFile()
        if df.shouldFsync:
          when defined(posix):
            discard fsync(df.file.getFileHandle())
  else:
    # Immediate write path
    let record = Record(key: key, value: value, timestamp: timestamp)
    let encoded = record.encode()
    var crcVal = crc32(encoded)

    withLock(df.lock):
      let recordPos = df.size

      let crcWritten = df.file.writeBuffer(addr crcVal, 4)
      if crcWritten != 4:
        raise newException(IOError, "Failed to write CRC32")

      let encWritten = df.file.writeBuffer(encoded.cstring, encoded.len)
      if encWritten != encoded.len:
        raise newException(IOError, "Failed to write record")

      df.size = df.size + 4.uint64 + encoded.len.uint64

      if df.groupCommitEnabled:
        df.pendingWrites += 1
        if forceSync:
          df.forceSync = true
        performGroupSync(df)
      else:
        df.file.flushFile()
        if df.shouldFsync:
          when defined(posix):
            discard fsync(df.file.getFileHandle())

      let recordDataPos = recordPos + 4
      let valuePos = recordDataPos + 8 + 4 + key.len.uint64

      result = RecordInfo(
        recordPos: recordDataPos,
        valuePos: valuePos,
        valueSize: value.len.uint32,
        recordSize: (4 + encoded.len).uint32
      )

# Re-export the original RecordInfo type
export record.RecordInfo