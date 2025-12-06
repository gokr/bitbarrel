## Data file implementation for Bitcask storage model

import std/[os, streams, strutils, times]
import kvs/types
from storage/record import crc32, Record, encode, decode

type
  DataFile* = object
    file*: File
    path*: string
    fileId*: uint32
    size*: uint64

  RecordInfo* = object
    recordPos*: uint64   # Position of the record (after CRC32)
    valuePos*: uint64    # Position of value within file
    valueSize*: uint32   # Size of value
    recordSize*: uint32  # Total record size

proc open*(path: string, fileId: uint32): DataFile =
  ## Open a data file, creating it if it doesn't exist
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
    file.setFilePos(0, fspEnd)
  else:
    file.setFilePos(0, fspEnd)

  let size = getFileSize(path).uint64

  result = DataFile(
    file: file,
    path: path,
    fileId: fileId,
    size: size
  )

proc close*(df: var DataFile) =
  ## Close the data file
  df.file.close()

proc readHeader*(df: DataFile): FileHeader =
  ## Read the file header
  let oldPos = df.file.getFilePos()
  df.file.setFilePos(0)

  var header: FileHeader
  let bytesRead = df.file.readBuffer(addr header, HEADER_SIZE)

  df.file.setFilePos(oldPos)

  if bytesRead != HEADER_SIZE:
    raise newException(IOError, "Failed to read file header")

  return header

proc appendRecord*(df: var DataFile, key: string, value: string, timestamp: int64): RecordInfo =
  ## Append a record to the data file
  let record = Record(
    key: key,
    value: value,
    timestamp: timestamp
  )

  let encoded = record.encode()
  let crcVal = crc32(encoded)

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

  # Calculate where the actual value starts (after record data CRC32 + timestamp + keyLen + key)
  let recordDataPos = recordPos + 4  # After CRC32
  let valuePos = recordDataPos + 8 + 4 + key.len.uint64  # timestamp + keyLen + key

  result = RecordInfo(
    recordPos: recordDataPos,
    valuePos: valuePos,
    valueSize: value.len.uint32,
    recordSize: (4 + encoded.len).uint32
  )

proc readRecord*(df: DataFile, recordInfo: RecordInfo): (string, string, int64) =
  ## Read a record using the recorded position information
  df.file.setFilePos(recordInfo.recordPos.int)

  # Read the record data (without CRC32)
  let recordDataLen = recordInfo.recordSize.int - 4  # Subtract CRC32
  var recordData = newString(recordDataLen)
  let bytesRead = df.file.readBuffer(addr recordData[0], recordDataLen)

  if bytesRead != recordDataLen:
    raise newException(IOError, "Failed to read record data")

  # Decode the record
  let record = decode(recordData)
  result = (record.key, record.value, record.timestamp)