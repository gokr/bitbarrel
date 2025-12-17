## Tests for compaction system

import std/[unittest, times, strformat, strutils, options]
import std/os except FileInfo
import ../src/bitbarrel/types
import ../src/storage/datafile
import ../src/storage/keydir
import ../src/storage/compact
import ../src/bitbarrel/barrel

const TestDir = "/tmp/bitbarrel_test_compact"

proc setupTest(): string =
  let testDir = TestDir & "_" & $getTime().toUnix()
  createDir(testDir)
  result = testDir

proc cleanupTest(testDir: string) =
  if dirExists(testDir):
    removeDir(testDir)

suite "Compaction Tests":

  test "Calculate fragmentation ratio":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    let path = testDir / "test.data"
    var df = datafile.open(path, 1'u32)
    var kd = keydir.init()
    defer: kd.deinit()

    # Add some records
    let now = getTime().toUnix()
    discard df.appendRecord("key1", "value1", now)
    discard df.appendRecord("key2", "value2", now)  # This will be deleted
    discard df.appendRecord("key3", "value3", now)
    df.close()

    # Reopen and delete key2
    df = datafile.open(path, 1'u32)
    discard df.appendRecord("key2", "", now)  # Tombstone
    df.close()

    # Calculate fragmentation
    let fragmentation = calculateFragmentation(path)

    check fragmentation.live == 3  # 3 live records
    check fragmentation.total == 4  # 4 total record
    check fragmentation.ratio == 0.25  # 25% fragmented (1 deleted)

  test "Compact controller initialization":
    var kd = keydir.init()
    defer: kd.deinit()

    let config = CompactConfig(
      enabled: true,
      triggerThreshold: 0.3,
      compactInterval: 60,
      compactIntervalBytes: 1024 * 1024,
      maxFileSize: 100 * 1024 * 1024
    )

    let controller = newCompactController(config, kd)
    check controller != nil
    check getCompactStats(controller).recordsScanned == 0

    controller.shutdown()

  test "Compaction below threshold":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    let path = testDir / "test.data"
    var df = datafile.open(path, 1'u32)
    var kd = keydir.init()

    # Add records with low fragmentation
    let now = getTime().toUnix()
    discard df.appendRecord("key1", "value1", now)
    discard df.appendRecord("key2", "value2", now)
    discard df.appendRecord("key3", "value3", now)

    # Add to KeyDir
    kd.add("key1", KeyDirEntry(fileId: 1, recordPos: 0, valuePos: 0, valueSize: 6, timestamp: now, recordSize: 30))
    kd.add("key2", KeyDirEntry(fileId: 1, recordPos: 30, valuePos: 0, valueSize: 6, timestamp: now, recordSize: 30))
    kd.add("key3", KeyDirEntry(fileId: 1, recordPos: 60, valuePos: 0, valueSize: 6, timestamp: now, recordSize: 30))

    df.close()

    let config = CompactConfig(
      enabled: true,
      triggerThreshold: 0.5,  # 50% threshold
      compactInterval: 60,
      compactIntervalBytes: 1024 * 1024,
      maxFileSize: 100 * 1024 * 1024
    )

    let controller = newCompactController(config, kd)

    # Try to compact (should skip due to low fragmentation)
    let compacted = performCompact(controller, path, 1'u32)
    check compacted == false  # Should not compact

    controller.shutdown()

  test "Compaction above threshold":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    let path = testDir / "test.data"
    var df = datafile.open(path, 1'u32)
    var kd = keydir.init()

    let now = getTime().toUnix()

    # Add initial records
    discard df.appendRecord("key1", "initial_value", now)
    discard df.appendRecord("key2", "initial_value", now)
    discard df.appendRecord("key3", "initial_value", now)

    # Add tombstones (deletes) and updates to create fragmentation
    discard df.appendRecord("key1", "", now)  # Delete key1
    discard df.appendRecord("key2", "updated_value", now)  # Update key2
    discard df.appendRecord("key3", "", now)  # Delete key3

    df.close()

    let config = CompactConfig(
      enabled: true,
      triggerThreshold: 0.3,  # 30% threshold
      compactInterval: 60,
      compactIntervalBytes: 1024 * 1024,
      maxFileSize: 100 * 1024 * 1024
    )

    let controller = newCompactController(config, kd)

    # Try to compact (should run due to high fragmentation)
    let compacted = performCompact(controller, path, 1'u32)

    check compacted == true  # Should compact

    # Check the new file exists
    let newPath = testDir / "000002.data"
    check fileExists(newPath)
    check not fileExists(path)  # Old file should be deleted

    # Verify stats
    let stats = getCompactStats(controller)
    check stats.recordsScanned > 0
    check stats.recordsDropped > 0  # Some tombstones should be dropped

    controller.shutdown()

  test "Compaction with expired records":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    let path = testDir / "test.data"
    var df = datafile.open(path, 1'u32)
    var kd = keydir.init()

    let expiredTime = (getTime() - 2.hours).toUnix()  # 2 hours ago
    let currentTime = getTime().toUnix()

    # Add an expired record
    discard df.appendRecord("expired_key", "expired_value", expiredTime)
    discard df.appendRecord("valid_key", "valid_value", currentTime)

    df.close()

    let config = CompactConfig(
      enabled: true,
      triggerThreshold: 0.0,  # Always compact
      compactInterval: 60,
      compactIntervalBytes: 1024 * 1024,
      maxFileSize: 100 * 1024 * 1024
    )

    let controller = newCompactController(config, kd)

    # Compact
    let compacted = performCompact(controller, path, 1'u32)

    check compacted == true

    # Check that expired record was dropped
    let stats = getCompactStats(controller)
    check stats.recordsDropped >= 1  # At least the expired record

    controller.shutdown()

  test "Compaction disabled":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    let path = testDir / "test.data"
    var df = datafile.open(path, 1'u32)
    var kd = keydir.init()

    let now = getTime().toUnix()
    discard df.appendRecord("key1", "", now)  # Just a tombstone
    df.close()

    let config = CompactConfig(
      enabled: false,  # Disabled!
      triggerThreshold: 0.0,
      compactInterval: 60,
      compactIntervalBytes: 1024 * 1024,
      maxFileSize: 100 * 1024 * 1024
    )

    let controller = newCompactController(config, kd)

    # Try to compact (should not run)
    let compacted = performCompact(controller, path, 1'u32)

    check compacted == false  # Should not compact

    controller.shutdown()

  test "Barrel integration - manual compaction":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    let barrelPath = testDir / "barrel.data"

    # Create barrel with compaction enabled
    var config = defaultBarrelConfig()
    config.autoCompact = true
    config.compactThreshold = 0.2  # 20% threshold

    var barrel = openBarrel(barrelPath, config)
    defer: close(barrel)

    # Add initial data
    check barrel.set("key1", "value1") == true
    check barrel.set("key2", "value2") == true
    check barrel.set("key3", "value3") == true

    # Delete some keys to create fragmentation
    check barrel.delete("key1") == true
    check barrel.delete("key3") == true

    # Update one key
    check barrel.set("key2", "updated_value2") == true

    # Trigger manual compaction
    let compacted = barrel.triggerCompact()
    check compacted == true

    # Verify barrel still works
    check barrel.get("key2") == "updated_value2"
    check not barrel.exists("key1")
    check not barrel.exists("key3")

    # Check compaction stats
    let stats = barrel.getCompactStats()
    check stats.recordsScanned > 0
    check stats.recordsDropped >= 2  # At least 2 tombstones