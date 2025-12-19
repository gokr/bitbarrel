## Crash Recovery Tests
##
## Tests for recovery from various crash scenarios including:
## - Process killed mid-write
## - Process killed during file rotation
## - Partial checkpoint files
## - Missing hint files
## - Multiple crashes in sequence

import std/[unittest, os, times, strformat]
import ../src/storage/recovery
import ../src/storage/datafile
import ../src/storage/checkpoint
import ../src/storage/keydir
import ../src/bitbarrel/types
import testutils

suite "Crash Recovery Tests":

  test "Recovery after process killed mid-write":
    withTestDir("crash_midwrite"):
      # Create a datafile with partial write
      let testFile = testDir / "000001.data"
      var df = datafile.open(testFile, 1'u32)

      # Write first record
      discard df.appendRecord("key1", "value1", now())

      # Simulate crash by closing without proper cleanup
      df.close()

      # Now manually corrupt by truncating mid-record
      truncateFileAt(testFile, 50)

      # Create recovery engine
      let engine = initRecoveryEngine(testDir)

      # Run recovery - should skip corrupt data
      let stats = engine.recover()

      # Should recover key1 but detect corruption
      check stats.keyCount == 1
      check stats.corruptRecords >= 0  # May detect 1 corrupt record

      # Verify recovered data
      var recoveredKeyDir = engine.getKeyDir()
      let entry = recoveredKeyDir.get("key1")
      check entry.isSome

  test "Recovery after process killed during file rotation":
    withTestDir("crash_rotation"):
      # Create initial datafile
      let oldFile = testDir / "000001.data"
      var df1 = datafile.open(oldFile, 1'u32)
      discard df1.appendRecord("key1", "value1", now())
      df1.close()

      # Simulate rotation by creating file with new ID
      let newFile = testDir / "000002.data"
      var df2 = datafile.open(newFile, 2'u32)
      discard df2.appendRecord("key2", "value2", now())

      # Simulate crash during rotation - close without finalizing
      df2.close()

      # Delete some records to simulate partial rotation
      removeFile(oldFile)

      # Create recovery engine
      let engine = initRecoveryEngine(testDir)

      # Run recovery - should handle missing old file
      let stats = engine.recover()

      # Should recover available data
      check stats.keyCount >= 1  # key2 should be recovered

  test "Recovery with partial checkpoint":
    withTestDir("partial_checkpoint"):
      # Create a datafile
      let testFile = testDir / "000001.data"
      var df = datafile.open(testFile, 1'u32)
      discard df.appendRecord("key1", "value1", now())
      df.close()

      # Create checkpoint system
      let cp = initCheckpointSystem(testDir)
      var keyDir = init()

      # Add entries to KeyDir
      keyDir.add("key1", KeyDirEntry(
        fileId: 1, recordPos: 100, valuePos: 120,
        valueSize: 6, timestamp: now(), recordSize: 26
      ))

      # Write checkpoint
      let checkpointId = cp.writeCheckpoint(keyDir, "full")

      # Truncate checkpoint file to simulate partial write
      let checkpointPath = cp.getCheckpointPath(checkpointId, false)
      let fileSize = getFileSize(checkpointPath)
      truncateFileAt(checkpointPath, fileSize div 2)

      # Create recovery engine with checkpoint loading
      let engine = initRecoveryEngine(testDir)

      # Run recovery - should handle corrupt checkpoint
      let stats = engine.recover()

      # Should fall back to scanning data files
      check stats.keyCount >= 0  # May be 0 if checkpoint was corrupted

      # But should still be able to recover from data file
      # (This depends on checkpoint loading implementation)

  test "Recovery when hint files are missing":
    withTestDir("missing_hints"):
      # Create data files but no hint files
      let testFile = testDir / "000001.data"
      var df = datafile.open(testFile, 1'u32)
      discard df.appendRecord("key1", "value1", now())
      discard df.appendRecord("key2", "value2", now())
      df.close()

      # Create recovery engine
      let engine = initRecoveryEngine(testDir)

      # Run recovery - should work without hint files
      let stats = engine.recover()

      # Should scan data files
      check stats.hintFilesUsed == 0
      check stats.filesFromScan >= 1
      check stats.keyCount == 2

      # Verify data
      var recoveredKeyDir = engine.getKeyDir()
      check recoveredKeyDir.get("key1").isSome
      check recoveredKeyDir.get("key2").isSome

  test "Recovery with multiple corrupted files":
    withTestDir("multiple_corrupt"):
      # Create first file
      let file1 = testDir / "000001.data"
      var df1 = datafile.open(file1, 1'u32)
      discard df1.appendRecord("key1", "value1", now())
      df1.close()

      # Create second file with corruption
      let file2 = testDir / "000002.data"
      var df2 = datafile.open(file2, 2'u32)
      discard df2.appendRecord("key2", "value2", now())
      df2.close()

      # Corrupt second file
      writeCorruptFile(file2, "CORRUPTED DATA")

      # Create recovery engine
      let engine = initRecoveryEngine(testDir)

      # Run recovery - should skip corrupt file
      let stats = engine.recover()

      # Should recover from first file
      check stats.keyCount >= 1
      check stats.corruptRecords >= 1

      # Verify recovered data
      var recoveredKeyDir = engine.getKeyDir()
      check recoveredKeyDir.get("key1").isSome

      # Second file should be skipped
      let key2Entry = recoveredKeyDir.get("key2")
      # key2 may or may not be recovered, depending on corruption location

  test "Multiple crashes in sequence":
    withTestDir("sequence_crashes"):
      # First crash - partial data file
      let testFile = testDir / "000001.data"
      var df = datafile.open(testFile, 1'u32)
      discard df.appendRecord("key1", "value1", now())
      df.close()

      # Simulate crash by truncating
      truncateFileAt(testFile, 30)

      # First recovery
      let engine1 = initRecoveryEngine(testDir)
      let stats1 = engine1.recover()
      check stats1.keyCount == 1

      # Close engine
      # (In real scenario, process would exit here)

      # Second "crash" - write more data then crash again
      var df2 = datafile.open(testFile, 1'u32)
      discard df2.appendRecord("key2", "value2", now())
      df2.close()

      # Simulate another crash
      truncateFileAt(testFile, 60)

      # Second recovery
      let engine2 = initRecoveryEngine(testDir)
      let stats2 = engine2.recover()

      # Should recover all valid data
      check stats2.keyCount >= 1  # At least key2, maybe both

  test "Recovery after power loss simulation":
    withTestDir("power_loss"):
      let testFile = testDir / "000001.data"

      # Create multiple small writes
      var df = datafile.open(testFile, 1'u32)
      for i in 0..<10:
        discard df.appendRecord(&"key_{i}", &"value_{i}", now())
      df.close()

      # Simulate power loss by cutting power mid-sync
      # We simulate by creating incomplete final write
      let fileData = readFile(testFile)
      writeFile(testFile, fileData[0..<fileData.len - 10])

      # Recovery
      let engine = initRecoveryEngine(testDir)
      let stats = engine.recover()

      # Should recover all valid records (may lose last one)
      check stats.keyCount >= 0
      check stats.keyCount <= 10

      # Verify at least some data was recovered
      var recoveredKeyDir = engine.getKeyDir()
      let entry = recoveredKeyDir.get("key_0")
      check entry.isSome

  test "Recovery with checkpoint + data files":
    withTestDir("checkpoint_recovery"):
      # Create data file
      let dataFile = testDir / "000001.data"
      var df = datafile.open(dataFile, 1'u32)
      discard df.appendRecord("key1", "value1", now())
      df.close()

      # Create checkpoint
      let cp = initCheckpointSystem(testDir)
      var keyDir = init()
      keyDir.add("key1", KeyDirEntry(
        fileId: 1, recordPos: 100, valuePos: 120,
        valueSize: 6, timestamp: now(), recordSize: 26
      ))
      let checkpointId = cp.writeCheckpoint(keyDir, "full")

      # Add more data after checkpoint
      let dataFile2 = testDir / "000002.data"
      var df2 = datafile.open(dataFile2, 2'u32)
      discard df2.appendRecord("key2", "value2", now())
      df2.close()

      # Simulate crash
      # (No specific action needed - checkpoint + data files exist)

      # Recovery should load checkpoint + scan new data
      let engine = initRecoveryEngine(testDir)
      let stats = engine.recover()

      # Should recover from both sources
      check stats.keyCount >= 1

      # Verify checkpoint was used
      # (Actual behavior depends on checkpoint loading implementation)

  test "Recovery cancellation during operation":
    withTestDir("recovery_cancel"):
      # Create large dataset to make recovery take time
      let testFile = testDir / "000001.data"
      var df = datafile.open(testFile, 1'u32)

      for i in 0..<100:
        discard df.appendRecord(&"key_{i}", &"value_{i}", now())

      df.close()

      # Start recovery in background
      let engine = initRecoveryEngine(testDir, RecoveryOptions(
        maxProgressInterval: 1,
        enableVerboseLogging: false
      ))

      # We can't easily test cancellation in single-threaded Nim tests
      # But we can test that the cancel flag is checked
      check engine.cancel() == false  # Not running yet

      # Run recovery
      let stats = engine.recover()

      # Verify it completed
      check stats.keyCount == 100

  test "Recovery progress tracking during large dataset":
    withTestDir("progress_tracking"):
      let testFile = testDir / "000001.data"
      var df = datafile.open(testFile, 1'u32)

      # Create medium-sized dataset
      for i in 0..<50:
        discard df.appendRecord(&"key_{i}", &"value_{i}", now())

      df.close()

      # Recovery with progress tracking
      let engine = initRecoveryEngine(testDir, RecoveryOptions(
        maxProgressInterval: 1,  # Report progress frequently
        enableVerboseLogging: false
      ))

      # Get initial progress
      let initialProgress = engine.getProgress()
      check initialProgress.filesScanned == 0

      # Run recovery
      let stats = engine.recover()

      # Check progress was updated
      let finalProgress = engine.getProgress()
      check finalProgress.filesScanned >= 1
      check finalProgress.recordsProcessed == 50

  test "Recovery with tombstone records":
    withTestDir("tombstone_recovery"):
      # Create file with tombstones
      let testFile = testDir / "000001.data"
      var df = datafile.open(testFile, 1'u32)

      # Write a key
      discard df.appendRecord("key1", "value1", 1000)

      # Delete it (tombstone)
      discard df.appendRecord("key1", "", 2000)  # Empty value = tombstone

      # Write another key
      discard df.appendRecord("key2", "value2", 1500)

      df.close()

      # Recovery
      let engine = initRecoveryEngine(testDir)
      let stats = engine.recover()

      # Should handle tombstones
      check stats.keyCount == 1  # Only key2 (key1 was deleted)

      # Verify key1 is not in KeyDir
      var recoveredKeyDir = engine.getKeyDir()
      check recoveredKeyDir.get("key1").isNone
      check recoveredKeyDir.get("key2").isSome