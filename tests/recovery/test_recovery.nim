## Recovery System Tests
##
## Test suite for crash recovery functionality

import std/[unittest, os, times, strutils, tables, options, strformat]
import ../../src/storage/[recovery, datafile, record, keydir, hintfile]
import ../../src/bitbarrel/types

# Utility for creating corrupt files
proc badWrite(path: string, content: string) =
  ## Write invalid/corrupt content to a file for testing
  let file = open(path, fmWrite)
  defer: file.close()
  file.write(content)

proc createTestDataFile(path: string, fileId: uint32, records: seq[Record]): bool =
  ## Create a test data file with the given records
  ## Returns true on success
  try:
    var df = datafile.open(path, fileId)

    for rec in records:
      discard df.appendRecord(rec.key, rec.value, rec.timestamp)

    df.close()
    return true
  except:
    return false

suite "Recovery System Tests":

  setup:
    # Create temporary test directory
    let testDir = "test_recovery_" & $getTime().toUnix()
    createDir(testDir)

  teardown:
    # Clean up test directory
    if dirExists(testDir):
      removeDir(testDir)

  test "RecoveryEngine initialization":
    let engine = initRecoveryEngine(testDir)
    check engine.dataDir == testDir
    check not engine.isRunning()
    check engine.getProgress().filesScanned == 0

  test "Scan data files":
    let engine = initRecoveryEngine(testDir)

    # Create some test data files
    let validFile = testDir / "000001.data"
    let invalidFile = testDir / "invalid.txt"
    let outOfOrderFile = testDir / "000003.data"

    validFile.writeFile("test data")
    invalidFile.writeFile("not a data file")
    outOfOrderFile.writeFile("test data")

    let dataFiles = engine.scanDataFiles()
    check dataFiles.len == 2
    check dataFiles[0].extractFilename() == "000001.data"
    check dataFiles[1].extractFilename() == "000003.data"

  test "Validate file header":
    let engine = initRecoveryEngine(testDir)

    # Create valid data file
    let validFile = testDir / "000001.data"
    var df = datafile.open(validFile, 1'u32)
    df.close()

    check engine.validateFileHeader(validFile) == true

    # Corrupt the file
    let corrupted = testDir / "000002.data"
    corrupted.writeFile("corrupted data")

    check engine.validateFileHeader(corrupted) == false

  test "Record reading during recovery":
    let engine = initRecoveryEngine(testDir)

    # Create test records
    let records = @[
      Record(timestamp: 1000, key: "key1", value: "value1"),
      Record(timestamp: 2000, key: "key2", value: "value2"),
      Record(timestamp: 1500, key: "del1", value: "")  # Tombstone
    ]

    # Create test data file
    let testFile = testDir / "000001.data"
    check createTestDataFile(testFile, 1'u32, records) == true

    # Read records back
    var offset: int64 = sizeof(FileHeader)
    var recoveredRecords: seq[Record]

    for i in 0..3:  # Try up to 4 times (last one should fail)
      let (record, bytesRead, isValid) = engine.readRecordFromFile(testFile, offset)
      if isValid and record != Record():
        recoveredRecords.add(record)
        offset += int64(bytesRead)
      else:
        break

    check recoveredRecords.len == 3
    check recoveredRecords[0].key == "key1"
    check recoveredRecords[1].key == "key2"
    check recoveredRecords[2].key == "del1"
    check recoveredRecords[2].value.len == 0  # Tombstone

  test "Full recovery from data files":
    let engine = initRecoveryEngine(testDir)

    # Create multiple data files with overlapping keys
    let file1Records = @[
      Record(timestamp: 1000, key: "key1", value: "value1"),
      Record(timestamp: 2000, key: "key2", value: "value2")
    ]

    let file2Records = @[
      Record(timestamp: 3000, key: "key1", value: "value1v2"),  # Newer version
      Record(timestamp: 2500, key: "key3", value: "value3")
    ]

    discard createTestDataFile(testDir / "000001.data", 1'u32, file1Records)
    discard createTestDataFile(testDir / "000002.data", 2'u32, file2Records)

    # Perform recovery
    let stats = engine.recover()

    check stats.totalFiles == 2
    check stats.totalRecords == 4
    check stats.validRecords == 4  # All records are valid (no tombstones)
    check stats.keyCount == 3     # key1, key2, key3 (duplicates merged)

    # Check KeyDir content
    var recoveredKeyDir = engine.getKeyDir()

    # key1 should have the latest value from file2
    var entry = recoveredKeyDir.get("key1").get()
    check entry.fileId == 2'u32
    check entry.timestamp == 3000

    # key2 should be from file1
    entry = recoveredKeyDir.get("key2").get()
    check entry.fileId == 1'u32
    check entry.timestamp == 2000

    # key3 should be from file2
    entry = recoveredKeyDir.get("key3").get()
    check entry.fileId == 2'u32
    check entry.timestamp == 2500

  test "Recovery with corrupt records":
    let engine = initRecoveryEngine(testDir, RecoveryOptions(
      validateChecksums: true,
      skipCorruptRecords: true
    ))

    # Create data file with some corrupt records
    let testFile = testDir / "000001.data"
    var df = datafile.open(testFile, 1'u32)

    # Write valid record
    discard df.appendRecord("key1", "value1", 1000)

    # Write some random bytes to create corrupt section
    df.file.write("corrupt_data_here")

    # Write another valid record
    discard df.appendRecord("key2", "value2", 2000)

    df.close()

    # Perform recovery - should skip corrupt parts
    let stats = engine.recover()
    check stats.validRecords >= 1  # At least some records should be valid
    check stats.corruptRecords >= 1  # Should detect corrupt data

  test "Recovery progress tracking":
    let engine = initRecoveryEngine(testDir, RecoveryOptions(
      maxProgressInterval: 1,  # Report every record
      enableVerboseLogging: false
    ))

    # Create some test data
    let records = @[
      Record(timestamp: 1000, key: "key1", value: "value1"),
      Record(timestamp: 2000, key: "key2", value: "value2")
    ]

    discard createTestDataFile(testDir / "000001.data", 1'u32, records)

    # Start recovery
    let stats = engine.recover()

    # Check progress
    let progress = engine.getProgress()
    check progress.filesScanned == 1
    check progress.recordsProcessed >= 2
    check progress.bytesScanned > 0

  test "Recovery cancellation":
    let engine = initRecoveryEngine(testDir)

    # Create test data
    let records = @[
      Record(timestamp: 1000, key: "key1", value: "value1"),
      Record(timestamp: 2000, key: "key2", value: "value2")
    ]

    discard createTestDataFile(testDir / "000001.data", 1'u32, records)

    # Test cancel when not running
    check engine.cancel() == false

    # Test cancel during recovery (in a simple scenario)
    # This is harder to test precisely due to single-threaded nature

suite "Integration Tests":

  setup:
    let testDir = "test_integration_" & $getTime().toUnix()
    createDir(testDir)

  teardown:
    if dirExists(testDir):
      removeDir(testDir)

  test "Crash recovery simulation":
    # Simulate a database that crashes during operation
    let engine = initRecoveryEngine(testDir)

    # Data file before crash
    let preCrashRecords = @[
      Record(timestamp: 1000, key: "key1", value: "value1"),
      Record(timestamp: 2000, key: "key2", value: "value2")
    ]

    discard createTestDataFile(testDir / "000001.data", 1'u32, preCrashRecords)

    # Simulate crash and recovery
    let stats = engine.recover()

    check stats.keyCount == 2
    check stats.totalFiles == 1

    # Verify data integrity
    var recoveredKeyDir = engine.getKeyDir()
    check recoveredKeyDir.get("key1").get().timestamp == 1000
    check recoveredKeyDir.get("key2").get().timestamp == 2000

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

    # Get data file size for hint file
    let dataFilePath = testDir / "000001.data"
    let dataSize = if fileExists(dataFilePath): getFileSize(dataFilePath).uint64 else: 0'u64

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
    check writeHintFile(hintPath, 1'u32, hintEntries, dataSize) == true

    # Run recovery with hint files enabled
    let stats = engine.recover()

    check stats.keyCount == 3
    check stats.hintFilesUsed == 1
    check stats.filesFromHint == 1
    check stats.filesFromScan == 0
    check stats.totalRecords == 0  # No records were scanned (hint covers entire file)

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

  test "Recovery performance with large dataset":
    let engine = initRecoveryEngine(testDir)

    # Create a substantial dataset
    var largeRecords: seq[Record]
    for i in 0..<1000:
      largeRecords.add(Record(
        timestamp: epochTime().int64,
        key: &"key{i:06d}",
        value: &"value{i:06d}_data"
      ))

    discard createTestDataFile(testDir / "000001.data", 1'u32, largeRecords)

    # Time the recovery
    let startTime = cpuTime()
    let stats = engine.recover()
    let recoveryTime = cpuTime() - startTime

    check stats.keyCount == 1000
    check stats.totalRecords == 1000
    check stats.validRecords == 1000

    # Performance should be reasonable (< 1 second for 1000 records)
    check recoveryTime < 1.0
