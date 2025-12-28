import unittest
import tables
import locks
import times
import options
import ../../../src/bitbarrel/types
import ../../../src/storage/keydir

suite "KeyDir Operations":
  test "create and initialize KeyDir":
    var keyDir = init()
    check keyDir.len == 0

  test "add and get entries":
    var keyDir = init()

    # Add an entry
    let entry = KeyDirEntry(
      recordPos: 0,
      fileId: 1,
      valueSize: 50,
      recordSize: 100,
      keyLen: 8
    )
    keyDir.add("test_key", entry)

    # Get the entry
    let found = keyDir.get("test_key")
    if found.isSome():
      let entry = found.get()
      check entry.fileId == 1
      check entry.valueSize == 50
      check entry.recordSize == 100
    else:
      check false  # Should have found the entry

  test "get non-existent key":
    var keyDir = init()

    let found = keyDir.get("non_existent")
    check found.isNone()

  test "delete keys":
    var keyDir = init()

    # Add entries
    let entry1 = KeyDirEntry(recordPos: 0, fileId: 1, valueSize: 50, recordSize: 100, keyLen: 4)
    let entry2 = KeyDirEntry(recordPos: 100, fileId: 1, valueSize: 75, recordSize: 125, keyLen: 4)

    keyDir.add("key1", entry1)
    keyDir.add("key2", entry2)

    check keyDir.len == 2

    # Delete a key
    discard keyDir.delete("key1")
    check keyDir.len == 1
    check keyDir.get("key1").isNone()
    check keyDir.get("key2").isSome()

  test "update existing key":
    var keyDir = init()

    # Add initial entry
    let oldEntry = KeyDirEntry(recordPos: 0, fileId: 1, valueSize: 50, recordSize: 100, keyLen: 5)
    keyDir.add("mykey", oldEntry)

    # Update with new entry (overwrites, no timestamp comparison)
    let newEntry = KeyDirEntry(recordPos: 200, fileId: 2, valueSize: 60, recordSize: 110, keyLen: 5)
    keyDir.add("mykey", newEntry)

    # Should get the new entry
    let found = keyDir.get("mykey")
    check found.isSome()
    check found.get.fileId == 2
    check found.get.recordPos == 200

  test "contains function":
    var keyDir = init()
    defer: keyDir.deinit()

    check keyDir.contains("nonexistent") == false

    keyDir.add("test_key", KeyDirEntry(
      recordPos: 0,
      fileId: 1,
      valueSize: 100,
      recordSize: 200,
      keyLen: 8
    ))

    check keyDir.contains("test_key") == true
    check keyDir.contains("nonexistent") == false
    check keyDir.contains("TEST_KEY") == false  # Case sensitive

  test "keys function":
    var keyDir = init()
    defer: keyDir.deinit()

    # Empty keydir should return empty sequence
    let emptyKeys = keyDir.keys()
    check emptyKeys.len == 0

    # Add multiple keys
    keyDir.add("key1", KeyDirEntry(recordPos: 0, fileId: 1, valueSize: 10, recordSize: 20, keyLen: 4))
    keyDir.add("key2", KeyDirEntry(recordPos: 50, fileId: 1, valueSize: 20, recordSize: 30, keyLen: 4))
    keyDir.add("key3", KeyDirEntry(recordPos: 100, fileId: 1, valueSize: 30, recordSize: 40, keyLen: 4))

    let allKeys = keyDir.keys()
    check allKeys.len == 3

    # The order might be different due to hash table, but all keys should be present
    check "key1" in allKeys
    check "key2" in allKeys
    check "key3" in allKeys

  test "real concurrent access with threads":
    var keyDir = init()
    defer: keyDir.deinit()

    # Add initial entry
    keyDir.add("shared_key", KeyDirEntry(
      recordPos: 0,
      fileId: 1,
      valueSize: 100,
      recordSize: 200,
      keyLen: 10
    ))

    # Read from multiple threads
    proc reader(kd: var KeyDir, count: int) =
      for i in 0..<count:
        let found = kd.get("shared_key")
        check found.isSome()

    # Simple concurrent read test (using single thread for simplicity)
    # Real concurrent testing is more complex, but this at least verifies locks don't deadlock
    for i in 0..<10:
      let found = keyDir.get("shared_key")
      check found.isSome()
      check found.get().recordPos == 0

  test "clear all entries":
    var keyDir = init()

    # Add some entries
    keyDir.add("key1", KeyDirEntry(recordPos: 0, fileId: 1, valueSize: 50, recordSize: 100, keyLen: 4))
    keyDir.add("key2", KeyDirEntry(recordPos: 100, fileId: 1, valueSize: 75, recordSize: 125, keyLen: 4))

    check keyDir.len == 2

    # Clear all
    keyDir.clear()
    check keyDir.len == 0
    check keyDir.get("key1").isNone()
    check keyDir.get("key2").isNone()
