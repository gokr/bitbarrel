## Range Management Tests
##
## Comprehensive tests for dynamic range splitting and merging

import unittest
import std/[os, times, strutils, sequtils, math]
import ../../../src/bitbarrel/barrel
import ../../../src/storage/orderedrange
import ../../../src/storage/rangeindex

# Test utilities
proc setupTestDir(prefix: string): string =
  ## Create a unique test directory
  result = prefix & "_" & $epochTime()
  createDir(result)

proc cleanupTestDir(dir: string) =
  ## Clean up test directory
  if dirExists(dir):
    removeDir(dir)

proc generateTestData(numKeys: int, keyLength: int = 10): seq[tuple[key: string, value: string]] =
  ## Generate test key-value pairs
  result = newSeq[tuple[key: string, value: string]](numKeys)
  for i in 0..<numKeys:
    # Generate keys with different prefixes for natural distribution
    let prefix = chr(ord('a') + (i mod 26))
    result[i] = (
      key: $prefix & "_key_" & $i.toHex(8),
      value: "value_" & $i
    )

# Unit tests for orderedrange.nim

suite "Range Management Configuration":
  test "default config values":
    var index = initRangeIndex(10, amCritBit, "test_data")
    let config = index.getManagementConfig()

    check config.enabled == false
    check config.splitThresholdKeys == 100000
    check config.mergeThresholdKeys == 10000
    check config.maxRangeSizeHintMB == 10
    check config.minRangeSizeHintMB == 1
    check config.autoSplit == true
    check config.autoMerge == true

    index.deinit()

  test "set custom config":
    var index = initRangeIndex(10, amCritBit, "test_data")
    var customConfig = index.getManagementConfig()

    customConfig.enabled = true
    customConfig.splitThresholdKeys = 50000
    customConfig.mergeThresholdKeys = 5000
    customConfig.autoSplit = false

    index.setManagementConfig(customConfig)
    let retrieved = index.getManagementConfig()

    check retrieved.enabled == true
    check retrieved.splitThresholdKeys == 50000
    check retrieved.mergeThresholdKeys == 5000
    check retrieved.autoSplit == false

    index.deinit()

  test "enable/disable management":
    var index = initRangeIndex(10, amCritBit, "test_data")

    index.enableRangeManagement(true)
    check index.getManagementConfig().enabled == true

    index.enableRangeManagement(false)
    check index.getManagementConfig().enabled == false

    index.deinit()

suite "Split/Merge Decision Logic":
    test "shouldSplitRange - below threshold":
      var config = RangeManagementConfig(
        enabled: true,
        splitThresholdKeys: 100000,
        mergeThresholdKeys: 10000,
        autoSplit: true,
        autoMerge: true
      )

      let meta = RangeMetadata(
        id: 0,
        keyCount: 50000,
        lastAccess: 0,
        hintPath: "",
        isLoaded: false,
        isDirty: false,
        minKey: "a",
        maxKey: "z",
        accessModel: amCritBit
      )

      check shouldSplitRange(meta, config) == false

    test "shouldSplitRange - at threshold":
      var config = RangeManagementConfig(
        enabled: true,
        splitThresholdKeys: 100000,
        mergeThresholdKeys: 10000,
        autoSplit: true,
        autoMerge: true
      )

      let meta = RangeMetadata(
        id: 0,
        keyCount: 100000,
        lastAccess: 0,
        hintPath: "",
        isLoaded: false,
        isDirty: false,
        minKey: "a",
        maxKey: "z",
        accessModel: amCritBit
      )

      check shouldSplitRange(meta, config) == false

    test "shouldSplitRange - above threshold":
      var config = RangeManagementConfig(
        enabled: true,
        splitThresholdKeys: 100000,
        mergeThresholdKeys: 10000,
        autoSplit: true,
        autoMerge: true
      )

      let meta = RangeMetadata(
        id: 0,
        keyCount: 150000,
        lastAccess: 0,
        hintPath: "",
        isLoaded: false,
        isDirty: false,
        minKey: "a",
        maxKey: "z",
        accessModel: amCritBit
      )

      check shouldSplitRange(meta, config) == true

    test "shouldSplitRange - management disabled":
      var config = RangeManagementConfig(
        enabled: false,
        splitThresholdKeys: 100000,
        mergeThresholdKeys: 10000,
        autoSplit: true,
        autoMerge: true
      )

      let meta = RangeMetadata(
        id: 0,
        keyCount: 150000,
        lastAccess: 0,
        hintPath: "",
        isLoaded: false,
        isDirty: false,
        minKey: "a",
        maxKey: "z",
        accessModel: amCritBit
      )

      check shouldSplitRange(meta, config) == false

    test "shouldMergeRanges - both below threshold":
      var config = RangeManagementConfig(
        enabled: true,
        splitThresholdKeys: 100000,
        mergeThresholdKeys: 10000,
        autoSplit: true,
        autoMerge: true
      )

      let left = RangeMetadata(
        id: 0,
        keyCount: 5000,
        lastAccess: 0,
        hintPath: "",
        isLoaded: false,
        isDirty: false,
        minKey: "a",
        maxKey: "h",
        accessModel: amCritBit
      )

      let right = RangeMetadata(
        id: 1,
        keyCount: 3000,
        lastAccess: 0,
        hintPath: "",
        isLoaded: false,
        isDirty: false,
        minKey: "i",
        maxKey: "p",
        accessModel: amCritBit
      )

      check shouldMergeRanges(left, right, config) == true

    test "shouldMergeRanges - one above threshold":
      var config = RangeManagementConfig(
        enabled: true,
        splitThresholdKeys: 100000,
        mergeThresholdKeys: 10000,
        autoSplit: true,
        autoMerge: true
      )

      let left = RangeMetadata(
        id: 0,
        keyCount: 5000,
        lastAccess: 0,
        hintPath: "",
        isLoaded: false,
        isDirty: false,
        minKey: "a",
        maxKey: "h",
        accessModel: amCritBit
      )

      let right = RangeMetadata(
        id: 1,
        keyCount: 15000,
        lastAccess: 0,
        hintPath: "",
        isLoaded: false,
        isDirty: false,
        minKey: "i",
        maxKey: "p",
        accessModel: amCritBit
      )

      check shouldMergeRanges(left, right, config) == false

    test "checkRangeHealth - healthy":
      var config = RangeManagementConfig(
        enabled: true,
        splitThresholdKeys: 100000,
        mergeThresholdKeys: 10000,
        autoSplit: true,
        autoMerge: true
      )

      let meta = RangeMetadata(
        id: 0,
        keyCount: 50000,
        lastAccess: 0,
        hintPath: "",
        isLoaded: false,
        isDirty: false,
        minKey: "a",
        maxKey: "z",
        accessModel: amCritBit
      )

      check checkRangeHealth(meta, config) == rhsHealthy
