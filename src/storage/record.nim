## Record format and encoding for Bitcask

import ../kvs/types

type
  Record* = object
    key*: string
    value*: string
    timestamp*: int64

proc crc32*(data: string): uint32 =
  ## Calculate CRC32 checksum (simplified implementation)
  result = 0xFFFFFFFF'u32
  for b in data:
    result = result xor b.uint32
    for i in 0..7:
      if (result and 1) != 0:
        result = (result shr 1) xor 0xEDB88320'u32
      else:
        result = result shr 1
  result = result xor 0xFFFFFFFF'u32

proc encode*(record: Record): string =
  ## Encode a record using portable binary format (little-endian)
  ## Format: [timestamp:8][keyLen:4][key][valLen:4][value]
  result = newString(8 + 4 + record.key.len + 4 + record.value.len)
  var pos = 0

  # Timestamp (8 bytes)
  copyMem(addr result[pos], addr record.timestamp, 8)
  pos += 8

  # Key length (4 bytes)
  var keyLen = record.key.len.uint32
  copyMem(addr result[pos], addr keyLen, 4)
  pos += 4

  # Key
  if record.key.len > 0:
    copyMem(addr result[pos], addr record.key[0], record.key.len)
  pos += record.key.len

  # Value length (4 bytes)
  var valLen = record.value.len.uint32
  copyMem(addr result[pos], addr valLen, 4)
  pos += 4

  # Value
  if record.value.len > 0:
    copyMem(addr result[pos], addr record.value[0], record.value.len)

proc decode*(data: string): Record =
  ## Decode a record from portable binary format (little-endian)
  var pos = 0

  # Read timestamp (8 bytes)
  if data.len - pos < 8:
    raise newException(ValueError, "Invalid record: missing timestamp")
  var timestamp: int64
  copyMem(addr timestamp, addr data[pos], 8)
  pos += 8

  # Read key length (4 bytes)
  if data.len - pos < 4:
    raise newException(ValueError, "Invalid record: missing key length")
  var keyLen: uint32
  copyMem(addr keyLen, addr data[pos], 4)
  pos += 4

  # Read key
  if data.len - pos < keyLen.int:
    raise newException(ValueError, "Invalid record: key data incomplete")
  let key = data[pos..<(pos+keyLen.int)]
  pos += keyLen.int

  # Read value length (4 bytes)
  if data.len - pos < 4:
    raise newException(ValueError, "Invalid record: missing value length")
  var valLen: uint32
  copyMem(addr valLen, addr data[pos], 4)
  pos += 4

  # Read value
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