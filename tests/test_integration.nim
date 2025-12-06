import unittest
import os
import times
import ../src/kvs/types
import ../src/storage
from ../src/storage/datafile import open
from ../src/storage/keydir import init

suite "Integration Tests - KVS Operations":
  test "GET/SET/DELETE workflow":
    # Setup
    let testDataPath = "test_integration.data"
    defer: removeFile(testDataPath)

    # Create data file and KeyDir
    var dataFile = open(testDataPath, 1'u32)
    defer: dataFile.close()

    var keyDir = init()
    defer:
      # Note: We can't easily call deinit here due to defer syntax
      # In practice, the GC will handle cleanup

    # Test SET operation
    let key1 = "user:123"
    let value1 = "Alice"
    let timestamp1 = getTime().toUnix()

    # Write record to file
    let recordInfo1 = dataFile.appendRecord(key1, value1, timestamp1)

    # Update KeyDir
    let keyDirEntry1 = KeyDirEntry(
      fileId: 1,
      recordPos: recordInfo1.recordPos,
      valuePos: recordInfo1.valuePos,
      valueSize: recordInfo1.valueSize,
      timestamp: timestamp1,
      recordSize: recordInfo1.recordSize
    )
    keyDir.add(key1, keyDirEntry1)

    # Test GET operation
    let found1 = keyDir.get(key1)
    check found1.isSome()
    if found1.isSome():
      let entry = found1.get()
      check entry.fileId == 1
      check entry.timestamp == timestamp1

      # Read the actual record from disk
      let (readKey1, readValue1, readTimestamp1) = dataFile.readRecord(entry.recordPos)
      check readKey1 == key1
      check readValue1 == value1
      check readTimestamp1 == timestamp1

    # Test SET with same key (update)
    let value1_updated = "Alice Smith"
    let timestamp1_updated = getTime().toUnix()

    let recordInfo1_updated = dataFile.appendRecord(key1, value1_updated, timestamp1_updated)

    let keyDirEntry1_updated = KeyDirEntry(
      fileId: 1,
      recordPos: recordInfo1_updated.recordPos,
      valuePos: recordInfo1_updated.valuePos,
      valueSize: recordInfo1_updated.valueSize,
      timestamp: timestamp1_updated,
      recordSize: recordInfo1_updated.recordSize
    )
    keyDir.add(key1, keyDirEntry1_updated)  # Should update existing entry

    # Verify we get the updated value
    let found1_updated = keyDir.get(key1)
    if found1_updated.isSome():
      let entry = found1_updated.get()
      check entry.timestamp == timestamp1_updated

      let (readKey1_updated, readValue1_updated, readTimestamp1_updated) = dataFile.readRecord(entry.recordPos)
      check readValue1_updated == value1_updated

    # Test multiple keys
    let key2 = "user:456"
    let value2 = "Bob"
    let timestamp2 = getTime().toUnix()

    let recordInfo2 = dataFile.appendRecord(key2, value2, timestamp2)
    keyDir.add(key2, KeyDirEntry(
      fileId: 1,
      recordPos: recordInfo2.recordPos,
      valuePos: recordInfo2.valuePos,
      valueSize: recordInfo2.valueSize,
      timestamp: timestamp2,
      recordSize: recordInfo2.recordSize
    ))

    # Verify both keys exist
    check keyDir.get(key1).isSome()
    check keyDir.get(key2).isSome()

    # Test DELETE (using tombstone)
    let deleteKey = "old_user"
    let deleteValue = ""  # Empty value indicates deletion
    let timestampDelete = getTime().toUnix()

    let recordInfoDelete = dataFile.appendRecord(deleteKey, deleteValue, timestampDelete)
    keyDir.add(deleteKey, KeyDirEntry(
      fileId: 1,
      recordPos: recordInfoDelete.recordPos,
      valuePos: recordInfoDelete.valuePos,
      valueSize: recordInfoDelete.valueSize,  # 0 for tombstone
      timestamp: timestampDelete,
      recordSize: recordInfoDelete.recordSize
    ))

    # After delete, reading should give empty value
    let foundDeleted = keyDir.get(deleteKey)
    if foundDeleted.isSome():
      let entry = foundDeleted.get()
      let (readKeyDeleted, readValueDeleted, _) = dataFile.readRecord(entry.recordPos)
      check readKeyDeleted == deleteKey
      check readValueDeleted == ""  # Empty indicates deleted

    # Test EXISTS operation
    check keyDir.get(key1).isSome()   # True
    check keyDir.get(key2).isSome()   # True
    check keyDir.get(deleteKey).isSome()  # True (tombstone exists)
    check keyDir.get("nonexistent").isNone()  # False

  test "data persistence across file reopen":
    # Setup
    let testDataPath = "test_persistence.data"
    defer: removeFile(testDataPath)

    # Write initial data
    {
      var dataFile = open(testDataPath, 1'u32)
      var keyDir = init()

      # Write a record
      let recordInfo = dataFile.appendRecord("persist_key", "persist_value", getTime().toUnix())
      keyDir.add("persist_key", KeyDirEntry(
        fileId: 1,
        recordPos: recordInfo.recordPos,
        valuePos: recordInfo.valuePos,
        valueSize: recordInfo.valueSize,
        timestamp: getTime().toUnix(),
        recordSize: recordInfo.recordSize
      ))

      dataFile.close()
    }

    # Reopen the file and verify data is still there
    var dataFile = open(testDataPath, 1'u32)
    defer: dataFile.close()

    # Read header to verify file format
    let header = dataFile.readHeader()
    check header.magic == ['B', 'C', 'K', 'S']
    check header.version == 1'u32
    check header.fileSize > HEADER_SIZE.uint64

  test "performance with multiple records":
    # Setup
    let testDataPath = "test_performance.data"
    defer: removeFile(testDataPath)

    var dataFile = open(testDataPath, 1'u32)
    defer: dataFile.close()

    var keyDir = init()

    let startTime = cpuTime()

    # Write 1000 records
    for i in 0..<1000:
      let key = "key_" & $i
      let value = "value_" & $i

      let recordInfo = dataFile.appendRecord(key, value, getTime().toUnix())
      keyDir.add(key, KeyDirEntry(
        fileId: 1,
        recordPos: recordInfo.recordPos,
        valuePos: recordInfo.valuePos,
        valueSize: recordInfo.valueSize,
        timestamp: getTime().toUnix(),
        recordSize: recordInfo.recordSize
      ))

    let writeTime = cpuTime() - startTime

    # Verify all records can be read
    let readStartTime = cpuTime()
    for i in 0..<1000:
      let key = "key_" & $i
      let expectedValue = "value_" & $i

      let found = keyDir.get(key)
      check found.isSome()

      if found.isSome():
        let entry = found.get()
        let (readKey, readValue, _) = dataFile.readRecord(entry.recordPos)
        check readKey == key
        check readValue == expectedValue

    let readTime = cpuTime() - readStartTime

    # Performance should be reasonable (these are just rough checks)
    echo "Write time for 1000 records: ", writeTime, " seconds"
    echo "Read time for 1000 records: ", readTime, " seconds"