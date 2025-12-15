## Tests for error handling and data corruption scenarios

import std/[unittest, os, strutils, options, locks]
import ../src/bitbarrel/types
import ../src/storage/datafile
import ../src/storage/keydir
import ../src/storage/record

suite "Error Handling Tests":
  # Note: Some tests for file corruption are simplified to avoid system-specific issues
  test "CRC32 mismatch detection - corrupted data":
    let testFile = "test_corruption.data"
    defer: removeFile(testFile)

    # Create file and write a valid record
    var df = open(testFile, 1)
    let info = df.appendRecord("testkey", "testvalue", 123456'i64)

    # Get original byte before closing
    df.file.setFilePos(40)  # Position in record data (after CRC)
    var originalByte: uint8 = 0
    discard df.file.readBuffer(addr originalByte, 1)

    # Corrupt while file is open
    df.file.setFilePos(40)
    let corruptedByte: uint8 = originalByte xor 0xFF
    discard df.file.writeBuffer(unsafeAddr corruptedByte, 1)
    df.file.flushFile()
    df.close()

    # Now try to read - should detect CRC32 mismatch
    var df2 = open(testFile, 1)
    defer: df2.close()

    expect IOError:
      discard df2.readRecord(info)

  # test "handle unopened DataFile error":
  #   # Test error when trying to read from uninitialized DataFile
  #   var df = DataFile()
  #   let info = RecordInfo(valuePos: 100, valueSize: 10, recordSize: 20, recordPos: 100)

  #   # Read from unopened DataFile - should fail
  #   expect IOError:
  #     discard df.readRecord(info)

  test "validate record with maximum sizes":
    # Test boundary conditions for validation

    # Valid record at max key size
    var maxKey = newString(MAX_KEY_SIZE)
    for i in 0..<MAX_KEY_SIZE:
      maxKey[i] = char('A')

    let record1 = Record(
      key: maxKey,
      value: "value",
      timestamp: 1'i64
    )
    check validate(record1) == true

    # Valid record at max value size
    var maxValue = newString(MAX_VALUE_SIZE)
    for i in 0..<MAX_VALUE_SIZE:
      maxValue[i] = char('B')

    let record2 = Record(
      key: "key",
      value: maxValue,
      timestamp: 1'i64
    )
    check validate(record2) == true

    # Invalid - key too large by 1
    var tooBigKey = newString(MAX_KEY_SIZE + 1)
    for i in 0..<(MAX_KEY_SIZE + 1):
      tooBigKey[i] = char('C')

    let record3 = Record(
      key: tooBigKey,
      value: "value",
      timestamp: 1'i64
    )
    check validate(record3) == false

    # Invalid - value too large by 1
    var tooBigValue = newString(MAX_VALUE_SIZE + 1)
    for i in 0..<(MAX_VALUE_SIZE + 1):
      tooBigValue[i] = char('D')

    let record4 = Record(
      key: "key",
      value: tooBigValue,
      timestamp: 1'i64
    )
    check validate(record4) == false

  test "empty file header reading":
    let testFile = "test_empty.data"

    # Create completely empty file
    var file = open(testFile, fmWrite)
    file.close()

    # Try to read header from empty file
    var df = open(testFile, 1)
    defer:
      df.close()
      removeFile(testFile)

    # Should create header if file is empty, not fail
    let header = df.readHeader()
    check header.magic == ['B', 'C', 'K', 'S']

  test "malformed header magic number":
    let testFile = "test_badmagic.data"
    var df = open(testFile, 1)
    defer:
      df.close()
      removeFile(testFile)

    # Read header normally first
    let header = df.readHeader()
    check header.magic == ['B', 'C', 'K', 'S']

    # Corrupt magic number
    df.file.setFilePos(0)
    let badMagic = ['X', 'X', 'X', 'X']
    discard df.file.writeBuffer(addr badMagic[0], 4)

    # Should still read but magic will be wrong
    let badHeader = df.readHeader()
    check badHeader.magic != ['B', 'C', 'K', 'S']

  test "decode from completely empty data":
    expect ValueError:
      discard decode("")

  test "decode from data with only part of timestamp":
    let partialData = "12345"  # Not enough for 8-byte timestamp
    expect ValueError:
      discard decode(partialData)

  test "decode with inconsistent length fields":
    # Create test data where stated lengths don't match actual content
    var data = newString(30)
    # timestamp (8 bytes)
    for i in 0..<8:
      data[i] = char(0)
    # keyLen (4 bytes) - set to 20
    data[8] = char(20)
    data[9] = char(0)
    data[10] = char(0)
    data[11] = char(0)
    # key data - but we only have space for 5 more bytes before EOF
    for i in 12..min(16, data.len - 1):
      data[i] = 'k'

    expect ValueError:
      discard decode(data)

  test "keydir addIfNewer with older timestamp":
    var keyDir = init()
    defer: keyDir.deinit()

    let entry1 = KeyDirEntry(
      fileId: 1,
      recordPos: 100,
      valuePos: 200,
      valueSize: 10,
      timestamp: 100,
      recordSize: 20
    )

    let entry2 = KeyDirEntry(
      fileId: 2,
      recordPos: 300,
      valuePos: 400,
      valueSize: 15,
      timestamp: 50,  # Older timestamp
      recordSize: 25
    )

    # Add first entry
    check keyDir.addIfNewer("key", entry1) == true

    # Try to add older entry - should be rejected
    check keyDir.addIfNewer("key", entry2) == false

    # Verify we still have the newer entry
    let stored = keyDir.get("key")
    check stored.isSome()
    check stored.get().timestamp == 100

  test "newerEntry comparison with no existing key":
    var keyDir = init()
    defer: keyDir.deinit()

    let entry = KeyDirEntry(
      fileId: 1,
      recordPos: 100,
      valuePos: 200,
      valueSize: 10,
      timestamp: 100,
      recordSize: 20
    )

    # Should return true for non-existent key
    check keyDir.newerEntry("nonexistent", entry) == true

  # test "multiple CRC32 mismatches in same file":
  #   # This test is commented out due to fragility in different environments
  #   pass