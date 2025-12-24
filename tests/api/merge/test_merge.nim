## Tests for merge/compaction system

import std/[unittest, times, tables, strformat, strutils]
import std/os except FileInfo
import ../../../src/bitbarrel/types
import ../../../src/storage/datafile
import ../../../src/storage/keydir
# TODO: Uncomment when merge module is implemented
# import storage/merge

const TestDir = "/tmp/bitbarrel_test_merge"

proc setupTest(): string =
  let testDir = TestDir & "_" & $getTime().toUnix()
  createDir(testDir)
  result = testDir

proc cleanupTest(testDir: string) =
  if dirExists(testDir):
    removeDir(testDir)

proc createTestDataFile(testDir: string, fileId: uint32, records: seq[tuple[key: string, value: string]]): FileInfo =
  ## Create a test data file with the given records
  let path = testDir / &"{fileId:06d}.data"
  var df = datafile.open(path, fileId)

  var totalRecords = 0
  var deleteCount = 0

  for (key, value) in records:
    discard df.appendRecord(key, value, getTime().toUnix())
    inc totalRecords
    if value.len == 0:
      inc deleteCount

  df.close()

  # Get actual file size from disk
  let size = getFileSize(path).uint64

  result = FileInfo(
    path: path,
    id: fileId,
    size: size,
    state: fsImmutable,
    created: getTime(),
    lastModified: getTime(),
    deleteCount: deleteCount,
    totalRecords: totalRecords,
    duplicateCount: 0,
    liveRecords: totalRecords - deleteCount
  )

suite "Merge System Tests":

  test "MergeController initialization":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    var keyDir = keydir.init()
    let config = MergeConfig(
      enabled: true,
      maxFileSize: 1024 * 1024,  # 1MB
      minFilesToMerge: 2,
      triggerThreshold: 0.3,
      maxMergeThreads: 1,
      mergeInterval: 60,
      mergeIntervalBytes: 0,
      skipThreshold: 0
    )

    let controller = newMergeController(config, keyDir, testDir)

    check controller != nil
    check controller.config.enabled == true
    check controller.dataDir == testDir
    check controller.mergeInProgress == false

  test "Calculate merge priority - fragmented file":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    var keyDir = keydir.init()
    let config = MergeConfig(
      enabled: true,
      maxFileSize: 1024 * 1024,
      minFilesToMerge: 2,
      triggerThreshold: 0.3,
      maxMergeThreads: 1,
      mergeInterval: 60,
      mergeIntervalBytes: 0,
      skipThreshold: 0
    )

    let controller = newMergeController(config, keyDir, testDir)

    # File with high fragmentation (50% deleted)
    let fileInfo = FileInfo(
      path: testDir / "000001.data",
      id: 1,
      size: 10000,
      state: fsImmutable,
      created: getTime(),
      lastModified: getTime() - initDuration(hours = 24),
      deleteCount: 50,
      totalRecords: 100,
      duplicateCount: 0,
      liveRecords: 50
    )

    let priority = controller.calculateMergePriority(fileInfo)

    # High fragmentation should give higher score
    check priority.score > 0.0
    check "Fragmentation" in priority.reason

  test "Select files for merge - minimum file count":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    var keyDir = keydir.init()
    let config = MergeConfig(
      enabled: true,
      maxFileSize: 1024 * 1024,
      minFilesToMerge: 2,
      triggerThreshold: 0.3,
      maxMergeThreads: 1,
      mergeInterval: 60,
      mergeIntervalBytes: 0,
      skipThreshold: 0
    )

    let controller = newMergeController(config, keyDir, testDir)

    # Add only 1 file - should not select any for merge
    let file1 = FileInfo(
      path: testDir / "000001.data",
      id: 1,
      size: 10000,
      state: fsImmutable,
      created: getTime(),
      lastModified: getTime(),
      deleteCount: 30,
      totalRecords: 100,
      duplicateCount: 0,
      liveRecords: 70
    )
    controller.activeFiles.add(file1)

    let selected = controller.selectFilesForMerge()
    check selected.len == 0  # Not enough files

  test "Select files for merge - with enough files":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    var keyDir = keydir.init()
    let config = MergeConfig(
      enabled: true,
      maxFileSize: 1024 * 1024,
      minFilesToMerge: 2,
      triggerThreshold: 0.1,  # Low threshold
      maxMergeThreads: 1,
      mergeInterval: 60,
      mergeIntervalBytes: 0,
      skipThreshold: 0
    )

    let controller = newMergeController(config, keyDir, testDir)

    # Add 3 files with deletions
    for i in 1..3:
      let file = FileInfo(
        path: testDir / &"{i:06d}.data",
        id: i.uint32,
        size: 10000,
        state: fsImmutable,
        created: getTime(),
        lastModified: getTime(),
        deleteCount: 30,
        totalRecords: 100,
        duplicateCount: 0,
        liveRecords: 70
      )
      controller.activeFiles.add(file)

    let selected = controller.selectFilesForMerge()
    check selected.len >= 2  # Should select files for merge

  test "readRecordAt - read record at specific offset":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    let path = testDir / "000001.data"
    var df = datafile.open(path, 1)

    # Write a record and get its position
    let recordInfo = df.appendRecord("testkey", "testvalue", 12345)

    # Read using readRecordAt
    let (key, value, timestamp, recordSize) = df.readRecordAt(recordInfo.recordPos - 4)  # Include CRC

    check key == "testkey"
    check value == "testvalue"
    check timestamp == 12345
    check recordSize > 0'u32

    df.close()

  test "readRecordAt - multiple records":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    let path = testDir / "000001.data"
    var df = datafile.open(path, 1)

    # Write multiple records
    var positions: seq[uint64] = @[]
    for i in 1..5:
      let info = df.appendRecord(&"key{i}", &"value{i}", i.int64)
      positions.add(info.recordPos - 4)  # CRC position

    # Read each record back
    for i, pos in positions:
      let (key, value, timestamp, _) = df.readRecordAt(pos)
      check key == &"key{i+1}"
      check value == &"value{i+1}"
      check timestamp == (i + 1).int64

    df.close()

  test "Merge - basic single file scan":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    var keyDir = keydir.init()
    let config = MergeConfig(
      enabled: true,
      maxFileSize: 1024 * 1024,
      minFilesToMerge: 1,
      triggerThreshold: 0.1,
      maxMergeThreads: 1,
      mergeInterval: 60,
      mergeIntervalBytes: 0,
      skipThreshold: 0
    )

    let controller = newMergeController(config, keyDir, testDir)

    # Create a test file with records
    let fileInfo = createTestDataFile(testDir, 1, @[
      ("key1", "value1"),
      ("key2", "value2"),
      ("key3", "value3")
    ])

    # Verify file was created with correct size
    check fileInfo.size > HEADER_SIZE.uint64

    # Run duplicate detection
    let (duplicates, total, tombstones, scanTime) = controller.findDuplicates(keyDir, fileInfo)

    check total == 3
    check duplicates == 0  # No duplicates (empty keyDir)
    check tombstones == 0
    check scanTime >= 0.0

  test "Merge - detect tombstones":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    var keyDir = keydir.init()
    let config = MergeConfig(
      enabled: true,
      maxFileSize: 1024 * 1024,
      minFilesToMerge: 1,
      triggerThreshold: 0.1,
      maxMergeThreads: 1,
      mergeInterval: 60,
      mergeIntervalBytes: 0,
      skipThreshold: 0
    )

    let controller = newMergeController(config, keyDir, testDir)

    # Create file with tombstones (empty values)
    let fileInfo = createTestDataFile(testDir, 1, @[
      ("key1", "value1"),
      ("key2", ""),  # Tombstone
      ("key3", "value3"),
      ("key4", "")   # Tombstone
    ])

    let (duplicates, total, tombstones, _) = controller.findDuplicates(keyDir, fileInfo)

    check total == 4
    check tombstones == 2  # Two tombstones

  test "getMergeStats - thread safe stats access":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    var keyDir = keydir.init()
    let config = MergeConfig(
      enabled: true,
      maxFileSize: 1024 * 1024,
      minFilesToMerge: 2,
      triggerThreshold: 0.3,
      maxMergeThreads: 1,
      mergeInterval: 60,
      mergeIntervalBytes: 0,
      skipThreshold: 0
    )

    let controller = newMergeController(config, keyDir, testDir)

    let stats = controller.getMergeStats()

    check stats.filesProcessed == 0
    check stats.recordsScanned == 0
    check stats.recordsKept == 0

  test "Background merge - start and stop worker":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    var keyDir = keydir.init()
    let config = MergeConfig(
      enabled: true,
      maxFileSize: 1024 * 1024,
      minFilesToMerge: 2,
      triggerThreshold: 0.3,
      maxMergeThreads: 1,
      mergeInterval: 60,
      mergeIntervalBytes: 0,
      skipThreshold: 0
    )

    let controller = newMergeController(config, keyDir, testDir)

    check controller.hasWorker == false

    controller.startMergeWorker()
    check controller.hasWorker == true

    # Give thread a moment to start
    sleep(10)

    controller.stopMergeWorker()
    check controller.hasWorker == false

    # Clean up resources
    controller.shutdown()

  test "Background merge - queue merge operation":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    var keyDir = keydir.init()
    let config = MergeConfig(
      enabled: true,
      maxFileSize: 1024 * 1024,
      minFilesToMerge: 1,
      triggerThreshold: 0.0,
      maxMergeThreads: 1,
      mergeInterval: 60,
      mergeIntervalBytes: 0,
      skipThreshold: 0
    )

    let controller = newMergeController(config, keyDir, testDir)
    controller.startMergeWorker()

    check controller.isMergePending() == false

    # Create some test files
    let file1 = createTestDataFile(testDir, 1, @[("key1", "value1")])
    let file2 = createTestDataFile(testDir, 2, @[("key2", "value2")])

    # Queue merge
    controller.queueMerge(@[file1, file2])

    # Check pending (might have already started)
    # Give a moment for the condition to be processed
    sleep(50)

    # Stop worker and clean up
    controller.stopMergeWorker()
    controller.shutdown()

  test "Background merge - isMergePending":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    var keyDir = keydir.init()
    let config = MergeConfig(
      enabled: true,
      maxFileSize: 1024 * 1024,
      minFilesToMerge: 2,
      triggerThreshold: 0.3,
      maxMergeThreads: 1,
      mergeInterval: 60,
      mergeIntervalBytes: 0,
      skipThreshold: 0
    )

    let controller = newMergeController(config, keyDir, testDir)

    # Initially no merge pending
    check controller.isMergePending() == false

    controller.shutdown()

  test "Background merge - triggerBackgroundMerge":
    let testDir = setupTest()
    defer: cleanupTest(testDir)

    var keyDir = keydir.init()
    let config = MergeConfig(
      enabled: true,
      maxFileSize: 1024 * 1024,
      minFilesToMerge: 2,
      triggerThreshold: 0.1,
      maxMergeThreads: 1,
      mergeInterval: 60,
      mergeIntervalBytes: 0,
      skipThreshold: 0
    )

    let controller = newMergeController(config, keyDir, testDir)
    controller.startMergeWorker()

    # Create test files with some fragmentation
    let file1 = createTestDataFile(testDir, 1, @[
      ("key1", "value1"),
      ("key2", "")  # tombstone
    ])
    let file2 = createTestDataFile(testDir, 2, @[
      ("key3", "value3"),
      ("key4", "")  # tombstone
    ])

    # Mark files as immutable and add to controller
    var file1Info = file1
    file1Info.state = fsImmutable
    file1Info.deleteCount = 1
    file1Info.totalRecords = 2

    var file2Info = file2
    file2Info.state = fsImmutable
    file2Info.deleteCount = 1
    file2Info.totalRecords = 2

    controller.activeFiles.add(file1Info)
    controller.activeFiles.add(file2Info)

    # Trigger background merge
    controller.triggerBackgroundMerge()

    # Wait for merge to complete
    sleep(200)

    controller.stopMergeWorker()
    controller.shutdown()
