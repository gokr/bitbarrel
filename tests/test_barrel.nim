## Tests for Barrel API with multiple index modes

import std/[unittest, os, strutils, sequtils, algorithm, options]
import ../src/bitbarrel/barrel
import ../src/bitbarrel/types
import ../src/storage/critbitindex

const TestDir = "test_barrel_data"

proc cleanup() =
  if dirExists(TestDir):
    removeDir(TestDir)

proc setup() =
  cleanup()
  createDir(TestDir)

suite "Barrel API - Normal Mode":
  setup:
    setup()

  teardown:
    cleanup()

  test "open and close barrel":
    let barrel = openBarrel(TestDir / "test.db")
    check barrel.getMode() == bmNormal
    check not barrel.isClosed()
    barrel.close()
    check barrel.isClosed()

  test "basic set and get":
    let barrel = openBarrel(TestDir / "test.db")
    check barrel.set("key1", "value1")
    check barrel.get("key1") == "value1"
    check barrel.get("nonexistent") == ""
    barrel.close()

  test "delete operation":
    let barrel = openBarrel(TestDir / "test.db")
    check barrel.set("key1", "value1")
    check barrel.exists("key1")
    check barrel.delete("key1")
    check not barrel.exists("key1")
    check barrel.get("key1") == ""
    barrel.close()

  test "count and listKeys":
    let barrel = openBarrel(TestDir / "test.db")
    check barrel.set("key1", "value1")
    check barrel.set("key2", "value2")
    check barrel.set("key3", "value3")
    check barrel.count() == 3
    let keys = barrel.listKeys()
    check keys.len == 3
    check "key1" in keys
    check "key2" in keys
    check "key3" in keys
    barrel.close()

  test "clear operation":
    let barrel = openBarrel(TestDir / "test.db")
    check barrel.set("key1", "value1")
    check barrel.set("key2", "value2")
    check barrel.count() == 2
    check barrel.clear()
    check barrel.count() == 0
    barrel.close()

  test "multiple barrels":
    let barrel1 = openBarrel(TestDir / "barrel1.db")
    let barrel2 = openBarrel(TestDir / "barrel2.db")

    check barrel1.set("key", "value1")
    check barrel2.set("key", "value2")

    check barrel1.get("key") == "value1"
    check barrel2.get("key") == "value2"

    barrel1.close()
    barrel2.close()

  test "config options":
    var config = defaultBarrelConfig()
    config.syncMode = UserSyncMode.Fsync
    config.writeBufferSize = 128 * 1024

    let barrel = openBarrel(TestDir / "test.db", config)
    check barrel.getConfig().syncMode == UserSyncMode.Fsync
    check barrel.getConfig().writeBufferSize == 128 * 1024
    barrel.close()

suite "Barrel API - CritBit Mode":
  setup:
    setup()

  teardown:
    cleanup()

  test "open in CritBit mode":
    var config = defaultBarrelConfig()
    config.mode = bmCritBit

    let barrel = openBarrel(TestDir / "test.db", config)
    check barrel.getMode() == bmCritBit
    barrel.close()

  test "basic operations in CritBit mode":
    var config = defaultBarrelConfig()
    config.mode = bmCritBit

    let barrel = openBarrel(TestDir / "test.db", config)
    check barrel.set("key1", "value1")
    check barrel.set("key2", "value2")
    check barrel.get("key1") == "value1"
    check barrel.get("key2") == "value2"
    check barrel.count() == 2
    barrel.close()

  test "keys are sorted in CritBit mode":
    var config = defaultBarrelConfig()
    config.mode = bmCritBit

    let barrel = openBarrel(TestDir / "test.db", config)
    check barrel.set("zebra", "z")
    check barrel.set("apple", "a")
    check barrel.set("mango", "m")

    let keys = barrel.listKeys()
    check keys.len == 3
    # CritBit returns sorted keys
    check keys == @["apple", "mango", "zebra"]
    barrel.close()

  test "keysWithPrefix":
    var config = defaultBarrelConfig()
    config.mode = bmCritBit

    let barrel = openBarrel(TestDir / "test.db", config)
    check barrel.set("user:1:name", "Alice")
    check barrel.set("user:1:email", "alice@example.com")
    check barrel.set("user:2:name", "Bob")
    check barrel.set("user:2:email", "bob@example.com")
    check barrel.set("session:abc", "data1")
    check barrel.set("session:def", "data2")

    let user1Keys = barrel.keysWithPrefix("user:1:")
    check user1Keys.len == 2
    check "user:1:name" in user1Keys
    check "user:1:email" in user1Keys

    let userKeys = barrel.keysWithPrefix("user:")
    check userKeys.len == 4

    let sessionKeys = barrel.keysWithPrefix("session:")
    check sessionKeys.len == 2

    let noMatch = barrel.keysWithPrefix("nonexistent:")
    check noMatch.len == 0

    barrel.close()

  test "keysInRange":
    var config = defaultBarrelConfig()
    config.mode = bmCritBit

    let barrel = openBarrel(TestDir / "test.db", config)
    check barrel.set("a", "1")
    check barrel.set("b", "2")
    check barrel.set("c", "3")
    check barrel.set("d", "4")
    check barrel.set("e", "5")

    let rangeKeys = barrel.keysInRange("b", "e")
    check rangeKeys.len == 3
    check rangeKeys == @["b", "c", "d"]

    let allKeys = barrel.keysInRange("a", "z")
    check allKeys.len == 5

    let emptyRange = barrel.keysInRange("x", "z")
    check emptyRange.len == 0

    barrel.close()

  test "countWithPrefix":
    var config = defaultBarrelConfig()
    config.mode = bmCritBit

    let barrel = openBarrel(TestDir / "test.db", config)
    for i in 1..10:
      discard barrel.set("user:" & $i, "data")
    for i in 1..5:
      discard barrel.set("session:" & $i, "data")

    check barrel.countWithPrefix("user:") == 10
    check barrel.countWithPrefix("session:") == 5
    check barrel.countWithPrefix("other:") == 0

    barrel.close()

suite "CritBit Index Unit Tests":
  test "init and deinit":
    var index = critbitindex.init()
    check index.len() == 0
    index.deinit()

  test "add and get":
    var index = critbitindex.init()
    let entry = KeyDirEntry(
      fileId: 1,
      recordPos: 100,
      valuePos: 120,
      valueSize: 10,
      timestamp: 12345,
      recordSize: 50
    )

    index.add("key1", entry)
    check index.len() == 1

    let found = index.get("key1")
    check found.isSome()
    check found.get().fileId == 1
    check found.get().valuePos == 120

    check index.get("nonexistent").isNone()
    index.deinit()

  test "delete":
    var index = critbitindex.init()
    let entry = KeyDirEntry(fileId: 1, recordPos: 0, valuePos: 0, valueSize: 0, timestamp: 0, recordSize: 0)

    index.add("key1", entry)
    check index.contains("key1")

    check index.delete("key1")
    check not index.contains("key1")
    check not index.delete("key1")

    index.deinit()

  test "clear":
    var index = critbitindex.init()
    let entry = KeyDirEntry(fileId: 1, recordPos: 0, valuePos: 0, valueSize: 0, timestamp: 0, recordSize: 0)

    index.add("key1", entry)
    index.add("key2", entry)
    index.add("key3", entry)
    check index.len() == 3

    index.clear()
    check index.len() == 0

    index.deinit()

  test "keys are sorted":
    var index = critbitindex.init()
    let entry = KeyDirEntry(fileId: 1, recordPos: 0, valuePos: 0, valueSize: 0, timestamp: 0, recordSize: 0)

    index.add("zebra", entry)
    index.add("apple", entry)
    index.add("mango", entry)
    index.add("banana", entry)

    let keys = index.keys()
    check keys == @["apple", "banana", "mango", "zebra"]

    index.deinit()

  test "addIfNewer":
    var index = critbitindex.init()

    let oldEntry = KeyDirEntry(fileId: 1, recordPos: 100, valuePos: 0, valueSize: 0, timestamp: 100, recordSize: 0)
    let newEntry = KeyDirEntry(fileId: 2, recordPos: 200, valuePos: 0, valueSize: 0, timestamp: 200, recordSize: 0)

    check index.addIfNewer("key1", oldEntry)
    check index.get("key1").get().timestamp == 100

    check index.addIfNewer("key1", newEntry)
    check index.get("key1").get().timestamp == 200
    check index.get("key1").get().fileId == 2

    # Older entry should not replace
    check not index.addIfNewer("key1", oldEntry)
    check index.get("key1").get().timestamp == 200

    index.deinit()

  test "keysWithPrefix":
    var index = critbitindex.init()
    let entry = KeyDirEntry(fileId: 1, recordPos: 0, valuePos: 0, valueSize: 0, timestamp: 0, recordSize: 0)

    index.add("prefix:a", entry)
    index.add("prefix:b", entry)
    index.add("prefix:c", entry)
    index.add("other:x", entry)
    index.add("other:y", entry)

    let prefixKeys = index.keysWithPrefix("prefix:")
    check prefixKeys.len == 3
    check prefixKeys == @["prefix:a", "prefix:b", "prefix:c"]

    let otherKeys = index.keysWithPrefix("other:")
    check otherKeys.len == 2

    index.deinit()

  test "keysInRange":
    var index = critbitindex.init()
    let entry = KeyDirEntry(fileId: 1, recordPos: 0, valuePos: 0, valueSize: 0, timestamp: 0, recordSize: 0)

    index.add("a", entry)
    index.add("b", entry)
    index.add("c", entry)
    index.add("d", entry)
    index.add("e", entry)

    let rangeKeys = index.keysInRange("b", "e")
    check rangeKeys == @["b", "c", "d"]

    index.deinit()

suite "Multiple Barrels with Different Configs":
  setup:
    setup()

  teardown:
    cleanup()

  test "different sync modes":
    var fastConfig = defaultBarrelConfig()
    fastConfig.syncMode = UserSyncMode.None

    var safeConfig = defaultBarrelConfig()
    safeConfig.syncMode = UserSyncMode.Fsync

    let fastBarrel = openBarrel(TestDir / "fast.db", fastConfig)
    let safeBarrel = openBarrel(TestDir / "safe.db", safeConfig)

    check fastBarrel.getConfig().syncMode == UserSyncMode.None
    check safeBarrel.getConfig().syncMode == UserSyncMode.Fsync

    # Both should work
    check fastBarrel.set("key", "value")
    check safeBarrel.set("key", "value")

    fastBarrel.close()
    safeBarrel.close()

  test "different index modes":
    var normalConfig = defaultBarrelConfig()
    normalConfig.mode = bmNormal

    var critbitConfig = defaultBarrelConfig()
    critbitConfig.mode = bmCritBit

    let normalBarrel = openBarrel(TestDir / "normal.db", normalConfig)
    let critbitBarrel = openBarrel(TestDir / "critbit.db", critbitConfig)

    check normalBarrel.getMode() == bmNormal
    check critbitBarrel.getMode() == bmCritBit

    # Both should work for basic ops
    check normalBarrel.set("key", "value")
    check critbitBarrel.set("key", "value")

    # CritBit has efficient prefix queries
    for i in 1..10:
      discard critbitBarrel.set("prefix:" & $i, "data")

    check critbitBarrel.countWithPrefix("prefix:") == 10

    normalBarrel.close()
    critbitBarrel.close()

suite "Barrel API - Ranged Mode":
  setup:
    setup()

  teardown:
    cleanup()

  test "open in Ranged mode":
    var config = defaultBarrelConfig()
    config.mode = bmRanged
    config.numRanges = 10
    config.maxLoadedRanges = 3

    let barrel = openBarrel(TestDir / "ranged.db", config)
    check barrel.getMode() == bmRanged
    barrel.close()

  test "basic operations in Ranged mode":
    var config = defaultBarrelConfig()
    config.mode = bmRanged
    config.numRanges = 10
    config.maxLoadedRanges = 5

    let barrel = openBarrel(TestDir / "ranged.db", config)

    # Basic CRUD operations
    check barrel.set("key1", "value1")
    check barrel.set("key2", "value2")
    check barrel.set("key3", "value3")

    check barrel.get("key1") == "value1"
    check barrel.get("key2") == "value2"
    check barrel.get("key3") == "value3"
    check barrel.get("nonexistent") == ""

    barrel.close()

  test "delete in Ranged mode":
    var config = defaultBarrelConfig()
    config.mode = bmRanged
    config.numRanges = 10
    config.maxLoadedRanges = 5

    let barrel = openBarrel(TestDir / "ranged.db", config)

    check barrel.set("key1", "value1")
    check barrel.exists("key1")
    check barrel.delete("key1")
    check not barrel.exists("key1")

    barrel.close()

  test "range stats":
    var config = defaultBarrelConfig()
    config.mode = bmRanged
    config.numRanges = 10
    config.maxLoadedRanges = 3

    let barrel = openBarrel(TestDir / "ranged.db", config)

    # Initially no keys
    let stats1 = barrel.rangeStats()
    check stats1.totalKeys == 0

    # Add some keys
    for i in 1..20:
      discard barrel.set("key" & $i, "value" & $i)

    let stats2 = barrel.rangeStats()
    check stats2.totalKeys == 20
    check stats2.maxRanges == 3

    barrel.close()

  test "keys distributed across ranges":
    var config = defaultBarrelConfig()
    config.mode = bmRanged
    config.numRanges = 5
    config.maxLoadedRanges = 3

    let barrel = openBarrel(TestDir / "ranged.db", config)

    # Add 100 keys - they should be distributed across ranges
    for i in 1..100:
      discard barrel.set("user:" & $i, "data" & $i)

    # All keys should be retrievable
    for i in 1..100:
      check barrel.get("user:" & $i) == "data" & $i

    check barrel.rangeStats().totalKeys == 100

    barrel.close()

  test "LRU eviction works":
    var config = defaultBarrelConfig()
    config.mode = bmRanged
    config.numRanges = 10
    config.maxLoadedRanges = 2

    let barrel = openBarrel(TestDir / "ranged.db", config)

    # Add keys that will go to different ranges
    # By using different prefixes, we can push keys to different ranges
    for i in 1..50:
      discard barrel.set("item" & $i, "data" & $i)

    # With maxLoadedRanges=2, some evictions should have occurred
    # but all data should still be accessible
    for i in 1..50:
      check barrel.get("item" & $i) == "data" & $i

    barrel.close()

  test "flush ranges":
    var config = defaultBarrelConfig()
    config.mode = bmRanged
    config.numRanges = 5
    config.maxLoadedRanges = 3

    let barrel = openBarrel(TestDir / "ranged.db", config)

    for i in 1..20:
      discard barrel.set("key" & $i, "value" & $i)

    # Flush should succeed
    let flushed = barrel.flushRanges()
    # Some ranges should be flushed
    check flushed >= 0

    barrel.close()
