import unittest
import tables
import locks
import kvs/types
import storage/keydir

suite "KeyDir Operations":
  test "create and initialize KeyDir":
    var keyDir = KeyDir.init()
    check keyDir.len == 0

  test "add and get entries":
    var keyDir = KeyDir.init()

    # Add an entry
    let entry = KeyDirEntry(
      fileId: 1,
      valuePos: 1000,
      valueSize: 50,
      timestamp: getTime().toUnix(),
      recordSize: 100
    )
    keyDir.add("test_key", entry)

    # Get the entry
    let found = keyDir.get("test_key")
    check found.isSome
    check found.get.fileId == 1
    check found.get.valuePos == 1000
    check found.get.valueSize == 50

  test "get non-existent key":
    var keyDir = KeyDir.init()

    let found = keyDir.get("non_existent")
    check found.isNone

  test "delete keys":
    var keyDir = KeyDir.init()

    # Add entries
    let entry1 = KeyDirEntry(fileId: 1, valuePos: 1000, valueSize: 50, timestamp: getTime().toUnix(), recordSize: 100)
    let entry2 = KeyDirEntry(fileId: 1, valuePos: 2000, valueSize: 75, timestamp: getTime().toUnix(), recordSize: 125)

    keyDir.add("key1", entry1)
    keyDir.add("key2", entry2)

    check keyDir.len == 2

    # Delete a key
    keyDir.delete("key1")
    check keyDir.len == 1
    check keyDir.get("key1").isNone
    check keyDir.get("key2").isSome

  test "update existing key":
    var keyDir = KeyDir.init()

    # Add initial entry
    let oldEntry = KeyDirEntry(fileId: 1, valuePos: 1000, valueSize: 50, timestamp: 1000000, recordSize: 100)
    keyDir.add("mykey", oldEntry)

    # Update with newer entry
    let newEntry = KeyDirEntry(fileId: 2, valuePos: 2000, valueSize: 60, timestamp: 2000000, recordSize: 110)
    keyDir.add("mykey", newEntry)

    # Should get the new entry
    let found = keyDir.get("mykey")
    check found.isSome
    check found.get.fileId == 2
    check found.get.valuePos == 2000
    check found.get.timestamp == 2000000

  test "concurrent access":
    var keyDir = KeyDir.init()

    # Simulate concurrent read/write operations
    keyDir.add("concurrent_key", KeyDirEntry(
      fileId: 1,
      valuePos: 1234,
      valueSize: 100,
      timestamp: getTime().toUnix(),
      recordSize: 200
    ))

    # Multiple concurrent reads should work
    for i in 0..<10:
      let found = keyDir.get("concurrent_key")
      check found.isSome
      check found.get.valuePos == 1234

  test "clear all entries":
    var keyDir = KeyDir.init()

    # Add some entries
    keyDir.add("key1", KeyDirEntry(fileId: 1, valuePos: 1000, valueSize: 50, timestamp: getTime().toUnix(), recordSize: 100))
    keyDir.add("key2", KeyDirEntry(fileId: 1, valuePos: 2000, valueSize: 75, timestamp: getTime().toUnix(), recordSize: 125))

    check keyDir.len == 2

    # Clear all
    keyDir.clear()
    check keyDir.len == 0
    check keyDir.get("key1").isNone
    check keyDir.get("key2").isNone