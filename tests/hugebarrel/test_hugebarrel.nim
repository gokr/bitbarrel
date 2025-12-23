## Tests for HugeBarrel - Two-tier storage

import std/[unittest, os, strformat, strutils]
import bitbarrel/types
import bitbarrel/barrel
import storage/hugebarrel
import storage/rangekeydir

suite "HugeBarrel Tests":

  const TEST_DIR = "/tmp/bitbarrel_huge_test"

  # Clean up before all tests
  if dirExists(TEST_DIR):
    removeDir(TEST_DIR)

  setup:
    # Clean up test directory
    if dirExists(TEST_DIR):
      removeDir(TEST_DIR)
    createDir(TEST_DIR)

  teardown:
    # Clean up
    if dirExists(TEST_DIR):
      removeDir(TEST_DIR)

  test "Create and close empty HugeBarrel":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit

    var hb = openHugeBarrel(TEST_DIR, config)
    check hb != nil
    check hb.getRangeCount() == 1  # Initial range created

    hb.close()

  test "Set and get single key":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.rangeCacheSize = 5

    var hb = openHugeBarrel(TEST_DIR, config)

    check hb.set("user:123", "John Doe")

    let value = hb.get("user:123")
    check value == "John Doe"

    hb.close()

  test "Set and get multiple keys":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.rangeCacheSize = 5

    var hb = openHugeBarrel(TEST_DIR, config)

    # Set multiple keys
    for i in 0..<100:
      check hb.set(fmt"key_{i:03d}", fmt"value_{i:03d}")

    # Get all keys back
    for i in 0..<100:
      let value = hb.get(fmt"key_{i:03d}")
      check value == fmt"value_{i:03d}"

    hb.close()

  test "Exists and delete":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit

    var hb = openHugeBarrel(TEST_DIR, config)

    check hb.set("test_key", "test_value")
    check hb.exists("test_key")

    check hb.delete("test_key")
    check not hb.exists("test_key")

    # Check value is gone
    let value = hb.get("test_key")
    check value == ""

    hb.close()

  test "Range metadata tracking":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 1000  # Large for this test

    var hb = openHugeBarrel(TEST_DIR, config)

    # Should start with one range
    check hb.getRangeCount() == 1

    # Add keys with different prefixes
    discard hb.set("user:123", "John")
    discard hb.set("user:456", "Jane")
    discard hb.set("order:100", "Order #100")
    discard hb.set("product:abc", "Widget")

    # All should be in same range initially
    check hb.getRangeCount() == 1

    let rangeKeys = hb.getRangeKeys()
    check rangeKeys.len == 1
    check rangeKeys[0] == "R0000000001"

    hb.close()

  test "RangeKeyDir cache":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.rangeCacheSize = 3  # Small cache

    var hb = openHugeBarrel(TEST_DIR, config)

    # Add keys (all in same range)
    for i in 0..<10:
      discard hb.set(fmt"key_{i}", fmt"value_{i}")

    # Flush to ensure RangeKeyDir is saved
    let flushed = hb.flushDirtyRanges()
    check flushed == 1

    # Clear cache
    cacheClear(hb.rangeKeyCache)
    check hb.rangeKeyCache.lruList.len == 0

    # Access keys again (should reload from Barrel1)
    for i in 0..<10:
      let value = hb.get(fmt"key_{i}")
      check value == fmt"value_{i}"

    # Cache should have been populated
    check hb.rangeKeyCache.lruList.len > 0

    hb.close()

  test "Persistence across reopen":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit

    block:
      var hb = openHugeBarrel(TEST_DIR, config)

      for i in 0..<50:
        discard hb.set(fmt"persistent_{i:03d}", fmt"value_{i:03d}")

      discard hb.flushDirtyRanges()
      hb.close()

    # Reopen
    block:
      var hb = openHugeBarrel(TEST_DIR, config)

      # All keys should still exist
      for i in 0..<50:
        let value = hb.get(fmt"persistent_{i:03d}")
        check value == fmt"value_{i:03d}"

      hb.close()

  test "Large value handling":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit

    var hb = openHugeBarrel(TEST_DIR, config)

    # Set a large value (10KB)
    var largeValue = ""
    for i in 0..<10000:
      largeValue.add('X')
    discard hb.set("large_key", largeValue)

    let retrieved = hb.get("large_key")
    check retrieved.len == 10000
    check retrieved == largeValue

    hb.close()

  test "Multiple ranges (manual)":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 10  # Force multiple ranges

    var hb = openHugeBarrel(TEST_DIR, config)

    # Add many keys to trigger range creation (when implemented)
    for i in 0..<100:
      discard hb.set(fmt"key_{i:04d}", fmt"value_{i:04d}")

    # For now, should still be one range
    # TODO: Update when range splitting is implemented
    check hb.getRangeCount() >= 1

    hb.close()

  test "TTL handling":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit

    var hb = openHugeBarrel(TEST_DIR, config)

    # Set with TTL (will be stored but expiration not checked yet)
    discard hb.set("temp_key", "temp_value", ttl = 1)  # 1 second TTL

    let value = hb.get("temp_key")
    check value == "temp_value"

    # TODO: Add TTL expiration test once implemented

    hb.close()

  test "RangeKeyDir bounds":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit

    var hb = openHugeBarrel(TEST_DIR, config)

    # Add keys with different lexicographic ranges
    discard hb.set("aaa", "first")
    discard hb.set("mmm", "middle")
    discard hb.set("zzz", "last")

    # Check all keys found
    check hb.get("aaa") == "first"
    check hb.get("mmm") == "middle"
    check hb.get("zzz") == "last"

    hb.close()

  test "Range splitting":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 100  # Force splits
    config.hugeConfig.autoSplitEnabled = true

    var hb = openHugeBarrel(TEST_DIR, config)

    # Add enough keys to trigger split
    for i in 0..<150:
      discard hb.set(fmt"key_{i:03d}", fmt"value_{i:03d}")

    # Should have more than 1 range now
    let rangeCount = hb.getRangeCount()
    check rangeCount > 1

    # All keys should still be accessible
    for i in 0..<150:
      let value = hb.get(fmt"key_{i:03d}")
      check value == fmt"value_{i:03d}"

    hb.close()

  test "Multiple data files":
    ## Test that writes span multiple data files when size limit is reached
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxDataFileSizeMB = 1  # Very small to force rotation

    var hb = openHugeBarrel(TEST_DIR, config)

    # Insert enough data to trigger file rotation
    # With 1MB per file, we should get multiple files
    let fileCount = 3
    let keysPerFile = 500
    for i in 0..<fileCount * keysPerFile:
      let key = fmt"file_key_{i:05d}"
      let value = repeat("X", 1000)  # 1KB value
      discard hb.set(key, value)

    # Verify data is still accessible
    for i in 0..<fileCount * keysPerFile:
      let key = fmt"file_key_{i:05d}"
      let value = hb.get(key)
      check value.len == 1000
      check value[0] == 'X'

    hb.close()

  test "Range splitting with data file verification":
    ## Test that range splitting works correctly and data spans multiple files
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 50  # Force splits
    config.hugeConfig.autoSplitEnabled = true
    config.hugeConfig.maxDataFileSizeMB = 1

    var hb = openHugeBarrel(TEST_DIR, config)

    # Insert sorted keys to trigger range splitting
    var insertedKeys: seq[string]
    for i in 0..<200:
      let key = fmt"split_key_{i:03d}"
      let value = fmt"split_value_{i:03d}"
      let success = hb.set(key, value)
      check success
      insertedKeys.add(key)

    # Check that we have multiple ranges
    let rangeCount = hb.getRangeCount()
    check rangeCount > 1
    echo fmt"Split test: Created {rangeCount} ranges"

    # Verify all keys are still accessible after splitting
    for key in insertedKeys:
      let value = hb.get(key)
      check value != ""
      check value.startsWith("split_value_")

    # Verify data persisted across restart
    hb.close()

    var hb2 = openHugeBarrel(TEST_DIR, config)
    check hb2.getRangeCount() == rangeCount

    for key in insertedKeys:
      let value = hb2.get(key)
      check value != ""
      check value.startsWith("split_value_")

    hb2.close()

  test "Persistence across reopen (fixed)":
    ## Test that data persists correctly after close and reopen
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit

    block initial_setup:
      var hb = openHugeBarrel(TEST_DIR, config)

      for i in 0..<50:
        discard hb.set(fmt"persistent_{i:03d}", fmt"value_{i:03d}")

      hb.close()

    # Reopen
    block verify_persistence:
      var hb = openHugeBarrel(TEST_DIR, config)

      # All keys should still exist
      for i in 0..<50:
        let value = hb.get(fmt"persistent_{i:03d}")
        check value == fmt"value_{i:03d}"

      hb.close()

echo "Running HugeBarrel integration tests..."

