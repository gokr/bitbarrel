import unittest
import os
import times
import ../../../src/bitbarrel/types
import ../../../src/storage

suite "Data File Format":
  test "create and read data file header":
    # Setup
    let testFile = "test_000001.data"
    defer: removeFile(testFile)

    let created = getTime().toUnix()

    # Create a new data file
    var df = open(testFile, 1'u32)
    defer: df.close()

    # Read header back
    let header = df.readHeader()

    # Verify header
    check header.magic == ['B', 'C', 'K', 'S']
    check header.version == 1'u32
    check header.created == created
    check header.fileSize == HEADER_SIZE.uint64

  test "append and read record":
    # Setup
    let testFile = "test_000002.data"
    defer: removeFile(testFile)

    var df = open(testFile, 2'u32)
    defer: df.close()

    # Create a test record
    let key = "test_key"
    let value = "test_value"
    let timestamp = getTime().toUnix()

    # Append record
    let recordInfo = df.appendRecord(key, value, timestamp)
    check recordInfo.valuePos > HEADER_SIZE
    check recordInfo.valueSize == value.len.uint32
    check recordInfo.recordSize > 0

    # Read record back
    let (readKey, readValue, readTimestamp) = df.readRecord(recordInfo)
    check readKey == key
    check readValue == value
    check readTimestamp == timestamp

  test "handle multiple records":
    # Setup
    let testFile = "test_000003.data"
    defer: removeFile(testFile)

    var df = open(testFile, 3'u32)
    defer: df.close()

    # Create multiple test records
    let records = [
      ("key1", "value1"),
      ("key2", "value2"),
      ("key3", "value3")
    ]

    var recordInfos: seq[RecordInfo]

    # Append all records
    for (key, value) in records:
      let info = df.appendRecord(key, value, getTime().toUnix())
      recordInfos.add(info)

    # Verify all records can be read correctly
    for i, (key, value) in records:
      let (readKey, readValue, _) = df.readRecord(recordInfos[i])
      check readKey == key
      check readValue == value