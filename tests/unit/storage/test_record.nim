## Tests for record encoding, decoding, validation, and CRC32

import std/[unittest, times]
import ../../../src/storage/record
import ../../../src/bitbarrel/types
import ../../testutils

suite "Record Module Tests":
  test "CRC32 test vectors":
    for (input, expected) in crc32TestVectors:
      check crc32(input) == expected

  test "CRC32 consistency":
    # Same input should always produce same output
    let data = "Hello, World!"
    let crc1 = crc32(data)
    let crc2 = crc32(data)
    check crc1 == crc2

  test "CRC32 different inputs produce different outputs":
    let crc1 = crc32("hello")
    let crc2 = crc32("Hello")
    check crc1 != crc2

  test "encode and decode round-trip":
    let original = Record(
      key: "test_key",
      value: "test_value",
      timestamp: 1234567890'i64
    )

    let encoded = encode(original)
    let decoded = decode(encoded)

    check decoded.key == original.key
    check decoded.value == original.value
    check decoded.timestamp == original.timestamp

  test "encode and decode with empty value (tombstone)":
    let original = Record(
      key: "deleted_key",
      value: "",
      timestamp: 1234567890'i64
    )

    let encoded = encode(original)
    let decoded = decode(encoded)

    check decoded.key == original.key
    check decoded.value == ""
    check decoded.timestamp == original.timestamp
    check isTombstone(decoded)

  test "encode and decode with special characters":
    let original = Record(
      key: "key\x00with\nnull\tand\rspecial",
      value: "value\x00with\xFFbinary\x01data",
      timestamp: 9999999999'i64
    )

    let encoded = encode(original)
    let decoded = decode(encoded)

    check decoded.key == original.key
    check decoded.value == original.value
    check decoded.timestamp == original.timestamp

  test "encode and decode with large key":
    var largeKey = newString(1000)
    for i in 0..<1000:
      largeKey[i] = char(i mod 256)

    let original = Record(
      key: largeKey,
      value: "value",
      timestamp: 1'i64
    )

    let encoded = encode(original)
    let decoded = decode(encoded)

    check decoded.key == original.key
    check decoded.value == original.value

  test "encode and decode with large value":
    var largeValue = newString(10000)
    for i in 0..<10000:
      largeValue[i] = char(i mod 256)

    let original = Record(
      key: "key",
      value: largeValue,
      timestamp: 1'i64
    )

    let encoded = encode(original)
    let decoded = decode(encoded)

    check decoded.key == original.key
    check decoded.value == original.value

  test "validate accepts valid record":
    let record = Record(
      key: "valid_key",
      value: "valid_value",
      timestamp: getTime().toUnix()
    )
    check validate(record) == true

  test "validate rejects empty key":
    let record = Record(
      key: "",
      value: "value",
      timestamp: getTime().toUnix()
    )
    check validate(record) == false

  test "validate rejects oversized key":
    let oversizedKey = newString(MAX_KEY_SIZE + 1)
    let record = Record(
      key: oversizedKey,
      value: "value",
      timestamp: getTime().toUnix()
    )
    check validate(record) == false

  test "validate rejects oversized value":
    let oversizedValue = newString(MAX_VALUE_SIZE + 1)
    let record = Record(
      key: "key",
      value: oversizedValue,
      timestamp: getTime().toUnix()
    )
    check validate(record) == false

  test "validate rejects zero timestamp":
    let record = Record(
      key: "key",
      value: "value",
      timestamp: 0'i64
    )
    check validate(record) == false

  test "validate rejects negative timestamp":
    let record = Record(
      key: "key",
      value: "value",
      timestamp: -1'i64
    )
    check validate(record) == false

  test "validate accepts empty value (tombstone)":
    let record = Record(
      key: "key",
      value: "",
      timestamp: getTime().toUnix()
    )
    check validate(record) == true

  test "isTombstone detection":
    let tombstone = Record(key: "key", value: "", timestamp: 1'i64)
    let notTombstone = Record(key: "key", value: "value", timestamp: 1'i64)

    check isTombstone(tombstone) == true
    check isTombstone(notTombstone) == false

  test "decode fails on truncated timestamp":
    let shortData = "1234567"  # Only 7 bytes, need 8 for timestamp
    expect ValueError:
      discard decode(shortData)

  test "decode fails on truncated key length":
    # 8 bytes timestamp + incomplete key length
    let shortData = "12345678" & "12"
    expect ValueError:
      discard decode(shortData)

  test "decode fails on incomplete key":
    # Create data with timestamp(8) + keyLen(4) indicating 100 bytes but only provide 10
    var data = newString(8 + 4 + 10)
    # Set keyLen to 100 (little-endian)
    data[8] = char(100)
    data[9] = char(0)
    data[10] = char(0)
    data[11] = char(0)

    expect ValueError:
      discard decode(data)

  test "decode fails on missing value length":
    # timestamp(8) + keyLen(4) + key(1) but no value length
    var data = newString(8 + 4 + 1)
    data[8] = char(1)  # keyLen = 1
    data[12] = 'k'     # key

    expect ValueError:
      discard decode(data)

  test "decode fails on incomplete value":
    # timestamp(8) + keyLen(4) + key(1) + valLen(4) indicating 100 bytes but only 10
    var data = newString(8 + 4 + 1 + 4 + 10)
    data[8] = char(1)   # keyLen = 1
    data[12] = 'k'      # key
    data[13] = char(100) # valLen = 100 (little-endian)
    data[14] = char(0)
    data[15] = char(0)
    data[16] = char(0)

    expect ValueError:
      discard decode(data)

  test "encoded format is deterministic":
    let record = Record(key: "key", value: "value", timestamp: 12345'i64)
    let encoded1 = encode(record)
    let encoded2 = encode(record)
    check encoded1 == encoded2

  test "encoded size is correct":
    let record = Record(key: "abc", value: "12345", timestamp: 1'i64)
    let encoded = encode(record)
    # Size should be: timestamp(8) + keyLen(4) + key(3) + valLen(4) + flags(1) + algo(1) + value(5) = 26
    check encoded.len == 26
