## Tests for write buffer functionality

import std/[unittest, os, times, strformat]
import ../src/storage/datafile
import ../src/storage/writebuffer
import ../src/kvs/types

suite "Write Buffer Tests":
  test "write buffer initialization":
    var flushedCount = 0
    var buffer = initWriteBuffer(
      maxSize = 100,
      syncMode = syncBatched,
      batchSize = 10,
      flushIntervalMs = 100,
      flushCallback = proc(entries: seq[BufferedEntry]): bool {.gcsafe.} =
        # Simple callback for testing
        flushedCount += entries.len
        return true
    )

    check buffer.maxSize == 100
    check buffer.currentSize == 0
    check buffer.syncMode == syncBatched
    check buffer.batchSize == 10
    check buffer.flushCallback != nil

  test "parse size string":
    check parseSizeString("128MB") == 128 * 1024 * 1024'u64
    check parseSizeString("2GB") == 2'u64 * 1024 * 1024 * 1024
    check parseSizeString("512") == 512'u64

  test "DataFile with different sync modes":
    # Test immediate mode (no buffer)
    let dataFile1 = "test_datafile_1.data"
    var df1 = open(dataFile1, 1, syncImmediate, true, 0)
    defer:
      df1.close()
      removeFile(dataFile1)

    check df1.syncMode == syncImmediate
    check df1.shouldFsync == true
    check df1.writeBuffer == nil

    # Test buffered mode
    let dataFile2 = "test_datafile_2.data"
    var df2 = open(dataFile2, 2, syncBuffered, true, 100)
    defer:
      df2.close()
      removeFile(dataFile2)

    check df2.syncMode == syncBuffered
    check df2.shouldFsync == true
    check df2.writeBuffer != nil

  test "buffered write - immediate mode":
    let testDataFile = "test_buffered_write.data"
    var df = open(testDataFile, 1, syncBuffered, true, 50)
    defer:
      df.close()
      removeFile(testDataFile)

    let info = df.appendRecord("test_key", "test_value", 123456789)

    check info.valuePos > 0
    check info.valueSize == "test_value".len.uint32

  test "performance comparison - simple test":
    let testDataFile = "test_perf.data"
    var df = open(testDataFile, 1, syncBuffered, false, 1000)  # No fsync for speed
    defer:
      df.close()
      removeFile(testDataFile)

    let start = getTime()

    # Write 1000 records
    for i in 0..<1000:
      discard df.appendRecord(&"key_{i:04}", &"value_{i:06}", getTime().toUnix())

    let elapsed = getTime() - start
    let opsPerSec = 1000.0 / elapsed.inMilliseconds.float * 1000.0

    # With fsync disabled, this should be fast even with simple approach
    # In release mode, expect >100K ops/sec
    when defined(release):
      check opsPerSec > 50000.0
    else:
      # In debug mode, just check it runs
      check opsPerSec > 1000.0

  test "write buffer stats":
    let testDataFile = "test_buffer_stats.data"
    var df = open(testDataFile, 1, syncBatched, true, 10)
    defer:
      df.close()
      removeFile(testDataFile)

    # Wait a bit for any background work
    sleep(50)

    # Add some entries
    for i in 0..<5:
      discard df.appendRecord(&"test_{i}", &"value_{i}", getTime().toUnix())

    let stats = df.writeBuffer[].getStats()
    check stats.entriesWritten == 5
    check stats.maxBufferDepth == 5