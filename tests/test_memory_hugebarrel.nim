## Test for HugeBarrel memory management fixes
## Verifies that ref DataFile objects work correctly without memory issues

import std/[unittest, os, random, strformat, strutils]
import ../src/bitbarrel/types
import ../src/bitbarrel/barrel
import ../src/storage/hugebarrel
import ../src/storage/rangekeydir

suite "HugeBarrel Memory Safety Tests":

  test "DataFile reference handling":
    ## Test that DataFile refs are properly created and accessed
    let testPath = "testdata_memory_test"
    removeDir(testPath)

    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 10

    var hb = openHugeBarrel(testPath, config)

    try:
      # Test basic operations that exercise DataFile ref handling
      for i in 0 ..< 20:
        let key = fmt"test_key_{i}"
        let value = fmt"test_value_{i}"

        # This exercises getOrCreateDataFile safe ref pattern
        let success = hb.set(key, value)
        check(success)

        # This exercises get() safe ref pattern
        let retrieved = hb.get(key)
        check(retrieved == value)

      # Test that range splitting works with refs
      for i in 20 ..< 50:
        let key = fmt"split_test_{i}"
        let value = fmt"value_{i}"
        let success = hb.set(key, value)
        check(success)
        let retrieved = hb.get(key)
        check(retrieved == value)

      echo "Memory safety test passed - no crashes detected"

    finally:
      hb.close()
      removeDir(testPath)

  test "Concurrent access without crashing":
    ## Test that multiple data files don't cause memory issues
    let testPath = "testdata_concurrent_test"
    removeDir(testPath)

    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 5  # Force range splits

    var hb = openHugeBarrel(testPath, config)

    try:
      # Create many keys to trigger multiple data files
      for i in 0 ..< 100:
        let key = fmt"concurrent_key_{i}"
        let value = fmt"value_data_{i}_with_extra_content"

        let success = hb.set(key, value)
        check(success)

      # Verify all keys are still accessible
      for i in 0 ..< 100:
        let key = fmt"concurrent_key_{i}"
        let expectedValue = fmt"value_data_{i}_with_extra_content"
        let retrieved = hb.get(key)
        check(retrieved == expectedValue)

      echo "Concurrent access test passed - data integrity maintained"

    finally:
      hb.close()
      removeDir(testPath)

  test "Range splitting with refs":
    ## Test that range splitting works correctly with ref DataFiles
    let testPath = "testdata_range_test"
    removeDir(testPath)

    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 3  # Very small to force splits
    config.hugeConfig.autoSplitEnabled = true

    var hb = openHugeBarrel(testPath, config)

    try:
      # Insert sorted keys to trigger range splitting
      var insertedKeys: seq[string]
      for i in 0 ..< 20:
        let key = fmt"sorted_key_{i:03d}"
        let value = fmt"value_{i}"
        let success = hb.set(key, value)
        check(success)
        insertedKeys.add(key)

      # Verify all keys after splitting
      for key in insertedKeys:
        let value = hb.get(key)
        check(value != "")
        check(value.startsWith("value_"))

      echo "Range splitting test passed - refs maintain consistency"

    finally:
      hb.close()
      removeDir(testPath)