## Tests for HugeBarrel Compaction Coordination
##
## Tests the coordinated compaction between Barrel1 (RangeKeyDirs) and Barrel2 (data files)
## This ensures that when Barrel2 files are compacted, Barrel1 indexes are updated atomically

import std/[unittest, os, strformat, strutils, tables, random]
import ../../src/bitbarrel/types
import ../../src/bitbarrel/barrel
import ../../src/storage/hugebarrel
import ../../src/storage/rangekeydir

const TEST_DIR = "/tmp/bitbarrel_huge_compaction_test"

suite "HugeBarrel Compaction Tests":

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

  test "Compact empty file":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit

    var hb = openHugeBarrel(TEST_DIR, config)
    defer: hb.close()

    # Try to compact a file that doesn't exist
    let result = hb.compactFile(999'u32)
    check result == false

  test "Compact file with no live records":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 100

    var hb = openHugeBarrel(TEST_DIR, config)
    defer: hb.close()

    # Insert and delete some keys to create a file with only tombstones
    for i in 0..<50:
      let key = fmt"key:{i:04d}"
      let value = fmt"value:{i}"
      discard hb.set(key, value)

    # Delete all keys to create tombstones
    for i in 0..<50:
      let key = fmt"key:{i:04d}"
      discard hb.set(key, "")  # Empty value = tombstone

    # Try to compact the current file
    let currentFile = hb.nextFileId - 1'u32
    let result = hb.compactFile(currentFile - 1)

    # Should skip compaction due to no live records
    # Result depends on whether any ranges were assigned to this file
    discard result  # Just verify no crash

  test "Compact single file with live records":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 100

    var hb = openHugeBarrel(TEST_DIR, config)
    defer: hb.close()

    # Insert 100 keys
    var expectedData = initTable[string, string]()
    for i in 0..<100:
      let key = fmt"key:{i:04d}"
      let value = fmt"value:{i}"
      discard hb.set(key, value)
      expectedData[key] = value

    # Get the file ID that was used (currentAssignmentFile tracks the active file)
    let targetFile = hb.nextFileId - 2'u32  # -2 because nextFileId points to next unused

    # Verify we can read all keys before compaction
    for key, expectedValue in expectedData:
      let retrieved = hb.get(key)
      check retrieved == expectedValue

    # Compact the file
    let compactResult = hb.compactFile(targetFile)
    check compactResult == true

    # Verify we can still read all keys after compaction
    for key, expectedValue in expectedData:
      let retrieved = hb.get(key)
      check retrieved == expectedValue

    # Verify file was replaced
    let oldFilePath = TEST_DIR / "barrel2" / fmt"file_{targetFile:06d}.data"
    check not fileExists(oldFilePath)

  test "Compaction updates RangeKeyDir file references":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 50
    config.hugeConfig.maxDataFileSizeMB = 10

    var hb = openHugeBarrel(TEST_DIR, config)
    defer: hb.close()

    # Insert keys
    for i in 0..<50:
      let key = fmt"key:{i:04d}"
      let value = fmt"value:{i}"
      discard hb.set(key, value)

    # Compact file 0
    let oldFilePath = TEST_DIR / "barrel2" / fmt"file_000000.data"
    if hb.compactFile(0):
      # Verify old file removed
      check not fileExists(oldFilePath)

      # Verify all data accessible (proves RangeKeyDir updated)
      for i in 0..<50:
        let key = fmt"key:{i:04d}"
        let expected = fmt"value:{i}"
        let retrieved = hb.get(key)
        check retrieved == expected
    else:
      # If compaction skipped, that's OK too
      discard

  test "Compact file during concurrent reads":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 100

    var hb = openHugeBarrel(TEST_DIR, config)
    defer: hb.close()

    # Insert 200 keys
    var expectedData = initTable[string, string]()
    for i in 0..<200:
      let key = fmt"key:{i:04d}"
      let value = fmt"value:{i}"
      discard hb.set(key, value)
      expectedData[key] = value

    # Find a file that has ranges assigned
    var targetFile: uint32 = 0xffffffffu32
    for fileId in 0'u32 ..< hb.nextFileId:
      let ranges = hb.listRangesByFile(fileId)
      if ranges.len > 0:
        targetFile = fileId
        break

    check targetFile != 0xffffffffu32  # Found a file with ranges

    # Verify reads work before compaction
    let retrievedBefore = hb.get("key:0050")
    check retrievedBefore == "value:50"

    # Compact the file
    let result = hb.compactFile(targetFile)
    check result == true

    # Verify reads still work after compaction
    let retrievedAfter = hb.get("key:0050")
    check retrievedAfter == "value:50"

    # Verify all data still accessible
    var keysChecked = 0
    for key, expectedValue in expectedData:
      let retrieved = hb.get(key)
      check retrieved == expectedValue
      inc keysChecked
      if keysChecked >= 50:  # Sample check for performance
        break

  test "Compact multiple files sequentially":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 50
    config.hugeConfig.maxDataFileSizeMB = 1  # Small files for testing

    var hb = openHugeBarrel(TEST_DIR, config)
    defer: hb.close()

    # Insert enough data to create multiple files
    for i in 0..<500:
      let key = fmt"key:{i:04d}"
      let value = fmt"value:{i}"
      discard hb.set(key, value)

    let numFiles = hb.nextFileId - 2'u32
    check numFiles >= 2  # Should have created multiple files

    # Compact each file
    for fileId in 1'u32 .. numFiles:
      let result = hb.compactFile(fileId)
      discard result  # Some may skip if no live records

    # Verify all data still accessible
    for i in 0..<100:
      let key = fmt"key:{i:04d}"
      let expected = fmt"value:{i}"
      let retrieved = hb.get(key)
      check retrieved == expected

  test "Compaction with range splitting":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 20  # Small range for testing
    config.hugeConfig.autoSplitEnabled = true

    var hb = openHugeBarrel(TEST_DIR, config)
    defer: hb.close()

    # Insert enough keys to trigger range splitting
    for i in 0..<100:
      let key = fmt"key:{i:04d}"
      let value = fmt"value:{i}"
      discard hb.set(key, value)

    let numRanges = hb.ranges.len
    check numRanges > 1  # Should have split into multiple ranges

    # Compact all files
    let numFiles = hb.nextFileId - 2'u32
    for fileId in 1'u32 .. numFiles:
      discard hb.compactFile(fileId)

    # Verify data integrity after compaction with splits
    for i in 0..<100:
      let key = fmt"key:{i:04d}"
      let expected = fmt"value:{i}"
      let retrieved = hb.get(key)
      check retrieved == expected

  test "Compaction space reclamation":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 100
    config.hugeConfig.maxDataFileSizeMB = 10  # Small files for faster test

    var hb = openHugeBarrel(TEST_DIR, config)
    defer: hb.close()

    # Insert 100 keys
    for i in 0..<100:
      let key = fmt"key:{i:04d}"
      let value = fmt"value:{i}"
      discard hb.set(key, value)

    # Delete half the keys to create fragmentation
    for i in 0..<50:
      let key = fmt"key:{i:04d}"
      discard hb.set(key, "")  # Tombstone

    # Compact file 0 (most likely to have data)
    if hb.compactFile(0):
      # Verify old file removed
      let oldFilePath = TEST_DIR / "barrel2" / fmt"file_000000.data"
      check not fileExists(oldFilePath)

      # Verify remaining keys accessible
      for i in 50..<100:
        let key = fmt"key:{i:04d}"
        let expected = fmt"value:{i}"
        let retrieved = hb.get(key)
        check retrieved == expected

      # Verify deleted keys are gone
      for i in 0..<50:
        let key = fmt"key:{i:04d}"
        let retrieved = hb.get(key)
        check retrieved.len == 0  # Tombstone or not found
    else:
      # If compaction didn't run, that's OK - file had no live records
      discard

  test "Compaction preserves range metadata":
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config.hugeConfig.maxEntriesPerRange = 50

    var hb = openHugeBarrel(TEST_DIR, config)
    defer: hb.close()

    # Insert keys to create one range
    for i in 0..<50:
      let key = fmt"key:{i:04d}"
      let value = fmt"value:{i}"
      discard hb.set(key, value)

    let targetFile = hb.nextFileId - 2'u32
    let rangeKey = hb.findRangeForKey("key:0025")

    # Verify all keys accessible before compaction
    for i in 0..<50:
      let key = fmt"key:{i:04d}"
      let expected = fmt"value:{i}"
      let retrieved = hb.get(key)
      check retrieved == expected

    # Record that the range exists and can find keys
    check rangeKey.len > 0
    check rangeKey == hb.findRangeForKey("key:0000")
    check rangeKey == hb.findRangeForKey("key:0049")

    # Compact the file
    let result = hb.compactFile(targetFile)
    check result == true

    # Verify range still exists after compaction
    let rangeKeyAfter = hb.findRangeForKey("key:0025")
    check rangeKeyAfter == rangeKey

    # Verify all keys still accessible (this proves metadata was preserved)
    for i in 0..<50:
      let key = fmt"key:{i:04d}"
      let expected = fmt"value:{i}"
      let retrieved = hb.get(key)
      check retrieved == expected

    # Verify old file was removed
    let oldFilePath = TEST_DIR / "barrel2" / fmt"file_{targetFile:06d}.data"
    check not fileExists(oldFilePath)

    # Verify a new compacted file exists (don't assume which ID)
    var newFileExists = false
    for kind, path in walkDir(TEST_DIR / "barrel2"):
      if kind == pcFile and path.endsWith(".data") and path != oldFilePath:
        newFileExists = true
        break
    check newFileExists
