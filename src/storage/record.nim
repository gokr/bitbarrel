## Record format and encoding for Bitcask

import std/[endians, strutils, times]
import ../bitbarrel/types
import ./crc32
import ./compression

# Re-export crc32 for backwards compatibility
export crc32

# Compression flags
const
  COMPRESS_FLAG* = 0b00000001  # Bit 0: compression enabled

type
  Record* = object
    key*: string
    value*: string
    timestamp*: int64
    compressed*: bool  # Indicates if value is compressed
    algorithm*: uint8  # Algorithm ID (0=none, 1=LZ4, 2=Snappy)

proc encode*(record: Record; compressionConfig: ptr CompressionConfig = nil): string =
  ## Encode a record using portable binary format (little-endian)
  ## Format: [timestamp:8][keyLen:4][key][valLen:4][flags:1][algorithm:1][value]

  # Use default compression config if none provided
  var threshold = 256
  var compressionEnabledConfig = false

  if compressionConfig != nil:
    compressionEnabledConfig = compressionConfig[].enabled
    threshold = compressionConfig[].threshold
  else:
    compressionEnabledConfig = compressionEnabled

  # Determine if we should compress the value
  var shouldCompressValue = false
  var compressedValue: seq[byte] = @[]
  var finalValue: seq[byte] = @[]
  var flags: uint8 = 0
  var algoId: uint8 = 0

  # Check if value should be compressed
  if compressionEnabledConfig and shouldCompress(record.value.toOpenArrayByte(0, record.value.high), threshold):
    try:
      compressedValue = compress(record.value.toOpenArrayByte(0, record.value.high))
      # Only use compression if it's beneficial
      if isCompressionBeneficial(record.value.len, compressedValue.len):
        shouldCompressValue = true
        finalValue = compressedValue
        flags = flags or COMPRESS_FLAG
        algoId = algorithmId.uint8
      else:
        finalValue = cast[seq[byte]](record.value)
    except CompressionError:
      # Fall back to uncompressed if compression fails
      finalValue = cast[seq[byte]](record.value)
  else:
    finalValue = cast[seq[byte]](record.value)

  # Calculate total size
  let totalSize = 8 + 4 + record.key.len + 4 + 1 + 1 + finalValue.len
  result = newString(totalSize)
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

  # Value length (4 bytes, little-endian) - stores the *original* uncompressed size
  var valLen: uint32
  var srcValLen = record.value.len.uint32  # Original size, not compressed
  littleEndian32(addr valLen, addr srcValLen)
  copyMem(addr result[pos], addr valLen, 4)
  pos += 4

  # Flags (1 byte)
  result[pos] = char(flags)
  pos += 1

  # Algorithm ID (1 byte)
  result[pos] = char(algoId)
  pos += 1

  # Value (raw bytes - may be compressed)
  if finalValue.len > 0:
    copyMem(addr result[pos], addr finalValue[0], finalValue.len)

proc decode*(data: string): Record =
  ## Decode a record from portable binary format (little-endian)
  ## Handles both old format (no flags/algo) and new format
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

  # Read value length (4 bytes, little-endian) - stores uncompressed size
  if data.len - pos < 4:
    raise newException(ValueError, "Invalid record: missing value length")
  var valLen: uint32
  var rawValLen: uint32
  copyMem(addr rawValLen, addr data[pos], 4)
  littleEndian32(addr valLen, addr rawValLen)
  let originalValSize = valLen.int
  pos += 4

  # Check if we have flags and algorithm (new format)
  var flags: uint8 = 0
  var algoId: uint8 = 0
  var isCompressed = false

  # If there's enough data for flags and algorithm, read them
  # Otherwise, assume old format (uncompressed)
  if data.len - pos >= 2:
    flags = uint8(data[pos])
    pos += 1
    algoId = uint8(data[pos])
    pos += 1
    isCompressed = (flags and COMPRESS_FLAG) != 0
  else:
    # Old format - treat remaining data as uncompressed value
    isCompressed = false

  # Read value (raw bytes - may be compressed)
  if data.len - pos < 0:
    raise newException(ValueError, "Invalid record: value data incomplete")

  let storedValue = data[pos..data.high]
  var finalValue: string

  if isCompressed:
    try:
      let decompressed = decompress(storedValue.toOpenArrayByte(0, storedValue.high), originalValSize)
      finalValue = cast[string](decompressed)
    except CompressionError as e:
      raise newException(ValueError, "Decompression failed: " & e.msg)
  else:
    # Check if size matches expected for uncompressed data
    if storedValue.len != originalValSize and algoId == 0:
      # This might be old format where stored size is actual size
      finalValue = storedValue
    else:
      finalValue = storedValue

  result = Record(
    key: key,
    value: finalValue,
    timestamp: timestamp,
    compressed: isCompressed,
    algorithm: algoId
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

# TTL encoding/decoding functions
# We use a simple approach: store expiration in the high bits, not in timestamp itself
const
  EXPIRATION_SHIFT = 48  # Shift amount for expiration (48 bits = 2^48/1000 ~ 8 years)
  TIMESTAMP_MASK  = 0x0000FFFFFFFFFFFFF'i64

proc encodeTimestamp*(ts: int64, ttlSeconds: int): int64 =
  ## Encode timestamp with TTL in seconds
  ## Original timestamp in low bits, expiration in high bits
  if ttlSeconds == 0:
    return ts  # No expiration

  let expiration = ts div 1000 + ttlSeconds  # Expiration time in seconds
  result = (ts and TIMESTAMP_MASK) or (expiration shl EXPIRATION_SHIFT)

proc decodeTimestamp*(encoded: int64): tuple[ts: int64, hasExpiration: bool, expiration: int64] =
  ## Decode: returns timestamp, hasExpiration, expirationTimeSeconds
  let ts = encoded and TIMESTAMP_MASK
  let expiration = encoded shr EXPIRATION_SHIFT

  let hasExp = expiration > 0
  result = (ts, hasExp, expiration)

proc isExpired*(encodedTimestamp: int64): bool =
  ## Check if record is expired (uses current time)
  let (_, hasExp, expiration) = decodeTimestamp(encodedTimestamp)
  result = hasExp and (getTime().toUnix() >= expiration)

proc getRemainingTtl*(encodedTimestamp: int64): int =
  ## Get remaining TTL in seconds (0 if no expiration or expired)
  let (_, hasExp, expiration) = decodeTimestamp(encodedTimestamp)
  if not hasExp:
    return 0

  let now = getTime().toUnix()
  result = if expiration > now: expiration - now else: 0