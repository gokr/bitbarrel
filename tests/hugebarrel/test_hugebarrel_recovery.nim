import unittest, os, strformat
import storage/hugebarrel
import bitbarrel/barrel

const TEST_DIR = "test_hugebarrel_recovery"

suite "HugeBarrel Recovery Tests":
  setup:
    # Clean test directory
    if dirExists(TEST_DIR):
      removeDir(TEST_DIR)
    createDir(TEST_DIR)

  teardown:
    if dirExists(TEST_DIR):
      removeDir(TEST_DIR)

  test "Recovery from lost range metadata":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 100  # Small range for testing

    block initial_setup:
      var hb = openHugeBarrel(TEST_DIR, config)

      # Insert test data across multiple ranges
      for i in 0..<1000:
        discard hb.set(&"key_{i:04d}", &"value_{i:04d}")

      let initialRangeCount = hb.getRangeCount()
      check initialRangeCount > 0
      echo fmt"Created {initialRangeCount} ranges"

      hb.close()

    block recovery:
      # Simulate metadata loss by deleting __RANGES_METADATA__
      var hb = openHugeBarrel(TEST_DIR, config)
      discard hb.barrel1.delete("__RANGES_METADATA__")
      hb.close()

      # Open should trigger automatic rebuild
      var hb2 = openHugeBarrel(TEST_DIR, config)

      # Should have rebuilt ranges
      let rebuiltCount = hb2.getRangeCount()
      check rebuiltCount > 0
      echo fmt"Rebuilt {rebuiltCount} ranges"

      # All data should be accessible
      for i in 0..<1000:
        let value = hb2.get(&"key_{i:04d}")
        check value == &"value_{i:04d}"

      hb2.close()

  test "Recovery with corrupted metadata":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit

    block initial_setup:
      var hb = openHugeBarrel(TEST_DIR, config)
      discard hb.set("key_001", "value_001")
      discard hb.set("key_002", "value_002")
      discard hb.set("key_003", "value_003")
      hb.close()

    block corrupt_metadata:
      # Corrupt the metadata with invalid format
      var hb = openHugeBarrel(TEST_DIR, config)
      discard hb.barrel1.set("__RANGES_METADATA__", "corrupted_garbage_data_that_is_not_valid")
      hb.close()

    block should_recover:
      var hb = openHugeBarrel(TEST_DIR, config)

      # Should rebuild despite corrupted metadata
      check hb.get("key_001") == "value_001"
      check hb.get("key_002") == "value_002"
      check hb.get("key_003") == "value_003"

      # Verify metadata was saved
      let metadata = hb.barrel1.get("__RANGES_METADATA__")
      check metadata.len > 0
      check metadata != "corrupted_garbage_data_that_is_not_valid"

      hb.close()

  test "Recovery preserves all range boundaries":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 50  # Very small for many ranges

    var rangeCountBefore: int

    block setup:
      var hb = openHugeBarrel(TEST_DIR, config)

      # Insert enough data to create multiple ranges
      for i in 0..<500:
        discard hb.set(&"key_{i:04d}", &"value_{i:04d}")

      rangeCountBefore = hb.getRangeCount()
      check rangeCountBefore > 5  # Should have many ranges
      echo fmt"Created {rangeCountBefore} ranges"

      hb.close()

    block lose_metadata:
      var hb = openHugeBarrel(TEST_DIR, config)
      discard hb.barrel1.delete("__RANGES_METADATA__")
      hb.close()

    block recover_and_verify:
      var hb = openHugeBarrel(TEST_DIR, config)

      let rangeCountAfter = hb.getRangeCount()
      check rangeCountAfter > 5
      echo fmt"Rebuilt {rangeCountAfter} ranges"

      # Should have same number of ranges
      check rangeCountAfter == rangeCountBefore

      # All keys should be accessible
      for i in 0..<500:
        let value = hb.get(&"key_{i:04d}")
        check value == &"value_{i:04d}"

      hb.close()

  test "Multiple recovery cycles":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit

    for cycle in 1..3:
      block setup:
        var hb = openHugeBarrel(TEST_DIR, config)

        # Add data unique to this cycle
        for i in 0..<100:
          discard hb.set(&"key_cycle{cycle}_{i:03d}", &"value_cycle{cycle}_{i:03d}")

        hb.close()

      block lose_and_recover:
        var hb = openHugeBarrel(TEST_DIR, config)
        discard hb.barrel1.delete("__RANGES_METADATA__")
        hb.close()

        var hb2 = openHugeBarrel(TEST_DIR, config)

        # Verify all data from all cycles is accessible
        for c in 1..cycle:
          for i in 0..<100:
            let value = hb2.get(&"key_cycle{c}_{i:03d}")
            check value == &"value_cycle{c}_{i:03d}"

        hb2.close()
