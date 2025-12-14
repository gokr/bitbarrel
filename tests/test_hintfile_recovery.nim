## Hint File Recovery Tests
##
## Test suite for hint file integration with recovery system

import std/[unittest, os, strformat, times]
import ../src/storage/[recovery, datafile, hintfile, keydir, record]
import ../src/kvs/types

# Utility for creating corrupt files
proc badWrite(path: string, content: string) =
  ## Write invalid/corrupt content to a file for testing
  let file = open(path, fmWrite)
  defer: file.close()
  file.write(content)

suite "Hint File Recovery Tests":

  setup:
    let testDir = "test_hint_recovery_" & $getTime().toUnix()
    createDir(testDir)

  teardown:
    if dirExists(testDir):
      removeDir(testDir)

  test "Recovery with hint files - valid hint file":
    let engine = initRecoveryEngine(testDir)

    # Create test records
    let records = @[
      Record(timestamp: 1000, key: "key1", value: "value1"),
      Record(timestamp: 2000, key: "key2", value: "value2"),
      Record(timestamp: 1500, key: "key3", value: "value3")  # Out of order, tests timestamp ordering
    ]

    # Create data file
    discard createTestDataFile(testDir / "000001.data", 1'u32, records)

    # Create corresponding hint file
    var hintEntries: seq[HintEntry]
    for record in records:
      let entry = HintEntry(
        key: record.key,
        recordPos: 100,  # Dummy position
        valuePos: 120,   # Dummy position
        valueSize: record.value.len.uint32,
        timestamp: record.timestamp,
        recordSize: (record.key.len + record.value.len + 16).uint32
      )
      hintEntries.add(entry)

    let hintPath = testDir / "000001.hint"
    check writeHintFile(hintPath, 1'u32, hintEntries) == true

    # Run recovery with hint files enabled
    let stats = engine.recover()

    check stats.keyCount == 3
    check stats.hintFilesUsed == 1
    check stats.filesFromHint == 1
    check stats.filesFromScan == 0
    check stats.totalRecords == 0  # No records were scanned

  test "Recovery with hint files - no hint file":
    let engine = initRecoveryEngine(testDir)

    # Create test records
    let records = @[
      Record(timestamp: 1000, key: "key1", value: "value1"),
      Record(timestamp: 2000, key: "key2", value: "value2")
    ]

    # Create data file but NO hint file
    discard createTestDataFile(testDir / "000001.data", 1'u32, records)

    # Run recovery with hint files enabled
    let stats = engine.recover()

    check stats.keyCount == 2
    check stats.hintFilesUsed == 0
    check stats.filesFromHint == 0
    check stats.filesFromScan == 1
    check stats.totalRecords == 2
    check stats.validRecords == 2

  test "Recovery with hint files - corrupt hint file":
    let engine = initRecoveryEngine(testDir)

    # Create data file
    let records = @[Record(timestamp: 1000, key: "key1", value: "value1")]
    discard createTestDataFile(testDir / "000001.data", 1'u32, records)

    # Create corrupt hint file (invalid header)
    let hintPath = testDir / "000001.hint"
    badWrite(hintPath, "INVALID HEADER CONTENT")

    # Run recovery
    let stats = engine.recover()

    check stats.keyCount == 1  # Should recover from data file
    check stats.hintFilesInvalid == 1
    check stats.hintFilesUsed == 0
    check stats.filesFromHint == 0
    check stats.filesFromScan == 1

  test "Recovery with hint files disabled":
    let options = RecoveryOptions(
      useHintFiles: false,  # Disabled
      enableVerboseLogging: false
    )
    let engine = initRecoveryEngine(testDir, options)

    # Create test records
    let records = @[
      Record(timestamp: 1000, key: "key1", value: "value1"),
      Record(timestamp: 2000, key: "key2", value: "value2")
    ]

    # Create both data file and hint file
    discard createTestDataFile(testDir / "000001.data", 1'u32, records)

    var hintEntries: seq[HintEntry]
    for record in records:
      let entry = HintEntry(
        key: record.key,
        recordPos: 100,
        valuePos: 120,
        valueSize: record.value.len.uint32,
        timestamp: record.timestamp,
        recordSize: (record.key.len + record.value.len + 16).uint32
      )
      hintEntries.add(entry)

    let hintPath = testDir / "000001.hint"
    check writeHintFile(hintPath, 1'u32, hintEntries) == true

    # Run recovery with hint files disabled
    let stats = engine.recover()

    check stats.keyCount == 2
    check stats.hintFilesUsed == 0  # Should not use hint file
    check stats.filesFromHint == 0
    check stats.filesFromScan == 1  # Should scan data file

when isMainModule:
  echo "Running hint file recovery tests..."
  # Tests run automatically via unittest framework