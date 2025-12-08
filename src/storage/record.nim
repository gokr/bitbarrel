## Record format and encoding for Bitcask

import std/endians
import ../kvs/types

type
  Record* = object
    key*: string
    value*: string
    timestamp*: int64

# CRC32 lookup table for fast computation (IEEE 802.3 polynomial)
const CRC32_TABLE: array[256, uint32] = block:
  var table: array[256, uint32]
  for i in 0'u32 ..< 256'u32:
    var crc = i
    for j in 0 ..< 8:
      if (crc and 1) != 0:
        crc = (crc shr 1) xor 0xEDB88320'u32
      else:
        crc = crc shr 1
    table[i] = crc
  table

proc crc32*(data: string): uint32 =
  ## Calculate CRC32 checksum using lookup table (10-100x faster than bit-by-bit)
  result = 0xFFFFFFFF'u32
  for b in data:
    let index = (result xor b.uint32) and 0xFF
    result = (result shr 8) xor CRC32_TABLE[index]
  result = result xor 0xFFFFFFFF'u32

proc encode*(record: Record): string =
  ## Encode a record using portable binary format (little-endian)
  ## Format: [timestamp:8][keyLen:4][key][valLen:4][value]
  result = newString(8 + 4 + record.key.len + 4 + record.value.len)
  var pos = 0

  # Timestamp (8 bytes, little-endian)
  var ts: int64
  littleEndian64(addr ts, addr record.timestamp)
  copyMem(addr result[pos], addr ts, 8)
  pos += 8

  # Key length (4 bytes, little-endian)
  var keyLen: uint32
  var srcKeyLen = record.key.len.uint32
  littleEndian32(addr keyLen, addr srcKeyLen)
  copyMem(addr result[pos], addr keyLen, 4)
  pos += 4

  # Key (raw bytes, no endianness conversion needed)
  if record.key.len > 0:
    copyMem(addr result[pos], addr record.key[0], record.key.len)
  pos += record.key.len

  # Value length (4 bytes, little-endian)
  var valLen: uint32
  var srcValLen = record.value.len.uint32
  littleEndian32(addr valLen, addr srcValLen)
  copyMem(addr result[pos], addr valLen, 4)
  pos += 4

  # Value (raw bytes, no endianness conversion needed)
  if record.value.len > 0:
    copyMem(addr result[pos], addr record.value[0], record.value.len)

proc decode*(data: string): Record =
  ## Decode a record from portable binary format (little-endian)
  var pos = 0

  # Read timestamp (8 bytes, little-endian)
  if data.len - pos < 8:
    raise newException(ValueError, "Invalid record: missing timestamp")
  var timestamp: int64
  var rawTs: int64
  copyMem(addr rawTs, addr data[pos], 8)
  littleEndian64(addr timestamp, addr rawTs)
  pos += 8

  # Read key length (4 bytes, little-endian)
  if data.len - pos < 4:
    raise newException(ValueError, "Invalid record: missing key length")
  var keyLen: uint32
  var rawKeyLen: uint32
  copyMem(addr rawKeyLen, addr data[pos], 4)
  littleEndian32(addr keyLen, addr rawKeyLen)
  pos += 4

  # Read key (raw bytes)
  if data.len - pos < keyLen.int:
    raise newException(ValueError, "Invalid record: key data incomplete")
  let key = data[pos..<(pos+keyLen.int)]
  pos += keyLen.int

  # Read value length (4 bytes, little-endian)
  if data.len - pos < 4:
    raise newException(ValueError, "Invalid record: missing value length")
  var valLen: uint32
  var rawValLen: uint32
  copyMem(addr rawValLen, addr data[pos], 4)
  littleEndian32(addr valLen, addr rawValLen)
  pos += 4

  # Read value (raw bytes)
  if data.len - pos < valLen.int:
    raise newException(ValueError, "Invalid record: value data incomplete")
  let value = data[pos..<(pos+valLen.int)]

  result = Record(
    key: key,
    value: value,
    timestamp: timestamp
  )

proc validate*(record: Record): bool =
  ## Validate a record meets constraints
  if record.key.len == 0 or record.key.len > MAX_KEY_SIZE:
    return false
  if record.value.len > MAX_VALUE_SIZE:
    return false
  if record.timestamp <= 0:
    return false
  return true

proc isTombstone*(record: Record): bool =
  ## Check if record is a tombstone (deleted record)
  ## We use empty value to indicate deletion
  return record.value.len == 0