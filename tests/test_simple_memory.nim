## Simple memory safety test - just create and destroy to ensure no crashes

import std/[unittest, os, strformat]
import ../src/bitbarrel/types
import ../src/bitbarrel/barrel
import ../src/storage/hugebarrel

suite "Simple Memory Safety Test":
  test "Create and close multiple times":
    let testPath = "testdata_simple"
    removeDir(testPath)

    for i in 0 ..< 5:
      var config = defaultBarrelConfig()
      config.mode = bmHugeCritBit
      config.hugeConfig.maxEntriesPerRange = 50

      var hb = openHugeBarrel(testPath, config)

      # Basic operations
      discard hb.set(fmt"key_{i}", fmt"value_{i}")
      check hb.get(fmt"key_{i}") == fmt"value_{i}"

      hb.close()

    removeDir(testPath)
    echo "Simple memory test passed - no crashes"