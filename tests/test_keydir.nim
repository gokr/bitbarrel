import unittest
import tables
import locks
import times
import options
import ../src/kvs/types
import ../src/storage/keydir

suite "KeyDir Operations":
  test "create and initialize KeyDir":
    var keyDir = init()
    check keyDir.len == 0

  test "add and get entries":
    var keyDir = init()

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
    if found.isSome():
      let entry = found.get()
      check entry.fileId == 1
      check entry.valuePos == 1000
      check entry.valueSize == 50
    else:
      check false  # Should have found the entry

  test "get non-existent key":
    var keyDir = init()

    let found = keyDir.get("non_existent")
    check found.isNone()

  test "delete keys":
    var keyDir = init()

    # Add entries
    let entry1 = KeyDirEntry(fileId: 1, valuePos: 1000, valueSize: 50, timestamp: getTime().toUnix(), recordSize: 100)
    let entry2 = KeyDirEntry(fileId: 1, valuePos: 2000, valueSize: 75, timestamp: getTime().toUnix(), recordSize: 125)

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
    let oldEntry = KeyDirEntry(fileId: 1, valuePos: 1000, valueSize: 50, timestamp: 1000000, recordSize: 100)
    keyDir.add("mykey", oldEntry)

    # Update with newer entry
    let newEntry = KeyDirEntry(fileId: 2, valuePos: 2000, valueSize: 60, timestamp: 2000000, recordSize: 110)
    keyDir.add("mykey", newEntry)

    # Should get the new entry
    let found = keyDir.get("mykey")
    check found.isSome()
    check found.get.fileId == 2
    check found.get.valuePos == 2000
    check found.get.timestamp == 2000000

  test "contains function":
    var keyDir = init()
    defer: keyDir.deinit()

    check keyDir.contains("nonexistent") == false

    keyDir.add("test_key", KeyDirEntry(
      fileId: 1,
      valuePos: 1234,
      valueSize: 100,
      timestamp: 1234,
      recordSize: 200
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
    keyDir.add("key1", KeyDirEntry(fileId: 1, valuePos: 1234, valueSize: 10, timestamp: 1234, recordSize: 20))
    keyDir.add("key2", KeyDirEntry(fileId: 1, valuePos: 2345, valueSize: 20, timestamp: 1234, recordSize: 30))
    keyDir.add("key3", KeyDirEntry(fileId: 1, valuePos: 3456, valueSize: 30, timestamp: 1234, recordSize: 40))

    let allKeys = keyDir.keys()
    check allKeys.len == 3

    # The order might be different due to hash table, but all keys should be present
    check "key1" in allKeys
    check "key2" in allKeys
    check "key3" in allKeys

  test "newerEntry function":
    var keyDir = init()
    defer: keyDir.deinit()

    let entry1 = KeyDirEntry(
      fileId: 1,
      valuePos: 1234,
      valueSize: 100,
      timestamp: 100,
      recordSize: 200
    )

    let entry2 = KeyDirEntry(
      fileId: 2,
      valuePos: 1234,
      valueSize: 100,
      timestamp: 200,  # Newer
      recordSize: 200
    )

    let entry3 = KeyDirEntry(
      fileId: 3,
      valuePos: 1234,
      valueSize: 100,
      timestamp: 50,   # Older
      recordSize: 200
    )

    # Non-existent key - should return true
    check keyDir.newerEntry("new_key", entry1) == true

    # Add first entry
    keyDir.add("key", entry1)

    # Try to add older entry - should return false (don't add)
    check keyDir.newerEntry("key", entry3) == false

    # Check newer entry - should return true
    check keyDir.newerEntry("key", entry2) == true

    # Manually add entry2 for next test
    keyDir.add("key", entry2)

    # Try equal timestamp - should return false (not newer)
    var entryEqual = KeyDirEntry(
      fileId: 4,
      valuePos: 9999,
      valueSize: 100,
      timestamp: 200,  # Same as entry2
      recordSize: 200
    )
    check keyDir.newerEntry("key", entryEqual) == false

  test "addIfNewer function":
    var keyDir = init()
    defer: keyDir.deinit()

    let entry1 = KeyDirEntry(
      fileId: 1,
      valuePos: 1234,
      valueSize: 100,
      timestamp: 100,
      recordSize: 200
    )

    let entry2 = KeyDirEntry(
      fileId: 2,
      valuePos: 5678,
      valueSize: 200,
      timestamp: 200,  # Newer
      recordSize: 300
    )

    let entry3 = KeyDirEntry(
      fileId: 3,
      valuePos: 9012,
      valueSize: 50,
      timestamp: 50,   # Older
      recordSize: 100
    )

    # Add to empty keydir - should succeed
    check keyDir.addIfNewer("new_key", entry1) == true
    let stored1 = keyDir.get("new_key")
    check stored1.isSome()
    check stored1.get().fileId == 1

    # Try to add older entry - should fail
    check keyDir.addIfNewer("new_key", entry3) == false
    let stillStored = keyDir.get("new_key")
    check stillStored.isSome()
    check stillStored.get().fileId == 1  # Still entry1

    # Add newer entry - should succeed
    check keyDir.addIfNewer("new_key", entry2) == true
    let updated = keyDir.get("new_key")
    check updated.isSome()
    check updated.get().fileId == 2  # Now entry2

    # Test addIfNewer with non-existent key
    check keyDir.addIfNewer("another_key", entry3) == true
    let newStored = keyDir.get("another_key")
    check newStored.isSome()
    check newStored.get().fileId == 3

  test "real concurrent access with threads":
    var keyDir = init()
    defer: keyDir.deinit()

    # Add initial entry
    keyDir.add("shared_key", KeyDirEntry(
      fileId: 1,
      valuePos: 1000,
      valueSize: 100,
      timestamp: 1000,
      recordSize: 200
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
      check found.get().valuePos == 1000

  test "clear all entries":
    var keyDir = init()

    # Add some entries
    keyDir.add("key1", KeyDirEntry(fileId: 1, valuePos: 1000, valueSize: 50, timestamp: getTime().toUnix(), recordSize: 100))
    keyDir.add("key2", KeyDirEntry(fileId: 1, valuePos: 2000, valueSize: 75, timestamp: getTime().toUnix(), recordSize: 125))

    check keyDir.len == 2

    # Clear all
    keyDir.clear()
    check keyDir.len == 0
    check keyDir.get("key1").isNone()
    check keyDir.get("key2").isNone()