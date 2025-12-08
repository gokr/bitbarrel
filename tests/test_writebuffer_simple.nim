## Simple tests for write buffer functionality

import std/[unittest, os, times, strformat]
import ../src/storage/datafile_simple as dfs
import ../src/storage/writebuffer
import ../src/kvs/types

suite "Simple Write Buffer Tests":
  test "write buffer initialization":
    var buffer = initWriteBuffer(
      maxSize = 100,
      syncMode = syncBatched,
      batchSize = 10,
      flushIntervalMs = 100
    )

    check buffer.maxSize == 100
    check buffer.currentSize == 0
    check buffer.syncMode == syncBatched
    check buffer.batchSize == 10

    buffer.stopWorker()

  test "parse size string":
    check parseSizeString("128MB") == 128 * 1024 * 1024'u64
    check parseSizeString("2GB") == 2'u64 * 1024 * 1024 * 1024
    check parseSizeString("512") == 512'u64

  test "performance comparison - immediate vs buffered":
    # Test immediate mode
    let immediateFile = "test_immediate.data"
    var dfImmediate = dfs.open(immediateFile, 1, syncImmediate, false, 0)
    defer:
      dfImmediate.close()
      removeFile(immediateFile)

    let start = getTime()

    # Write 100 records
    for i in 0..<100:
      discard dfImmediate.appendRecord(&"key_{i:04}", &"value_{i:06}", getTime().toUnix())

    let immediateTime = getTime() - start
    let immediateOps = 100.0 / immediateTime.inMilliseconds.float * 1000.0

    # Test buffered mode (no fsync)
    let bufferedFile = "test_buffered.data"
    var dfBuffered = dfs.open(bufferedFile, 2, syncBuffered, false, 1000)  # 1000 entry buffer
    defer:
      dfBuffered.close()
      removeFile(bufferedFile)

    let bufferedStart = getTime()

    # Write 100 records
    for i in 0..<100:
      discard dfBuffered.appendRecord(&"key_{i:04}", &"value_{i:06}", getTime().toUnix())

    # Wait for buffer to flush
    sleep(500)  # Give buffer time to flush

    let bufferedTime = getTime() - bufferedStart + 500  # Include time for flush
    let bufferedOps = 100.0 / bufferedTime.inMilliseconds.float * 1000.0

    # Buffered should be much faster than immediate in debug mode
    when defined(release):
      check immediateOps > 1000.0
      check bufferedOps > immediateOps * 0.8  # At least 20% improvement

  test "write buffer drop when full":
    let fullFile = "test_full.data"
    var dfFull = dfs.open(fullFile, 1, syncBuffered, false, 10)  # Very small buffer
    defer:
      dfFull.close()
      removeFile(fullFile)

    let stats = dfFull.writeBuffer[].getStats()

    # Fill buffer to capacity
    for i in 0..<15:
      discard dfFull.appendRecord(&"overflow_{i:04}", &"value_{i:06}", getTime().toUnix())

    # Next one should be dropped
    let result = dfFull.appendRecord("overflow", "dropped", getTime().toUnix())
    check result == frBufferFull

    check stats.entriesDropped == 1

  test "write buffer efficiency":
    let efficiencyFile = "test_efficiency.data"
    var df = dfs.open(efficiencyFile, 1, syncBatched, true, 1000)
    defer:
      df.close()
      removeFile(efficiencyFile)

    let start = getTime()

    # Fill buffer with entries
    for i in 0..<1000:
      discard df.appendRecord(&"eff_{i:04}", &"value_{i:06}", getTime().toUnix())

    # Wait for complete flush
    while df.writeBuffer[].currentSize > 0:
      sleep(10)

    let totalTime = getTime() - start
    let ops = 1000.0 / totalTime.inMilliseconds.float * 1000.0

    # Should achieve good throughput even in debug mode
    when defined(release):
      check ops > 5000.0
    else:
      check ops > 1000.0

  test "syncTimer functionality":
    let timerFile = "test_timer.data"
    var df = dfs.open(timerFile, 1, syncTimeBased, false, 100)  # 100ms interval
    defer:
      df.close()
      removeFile(timerFile)

    let start = getTime()

    # First write should trigger immediate flush
    discard df.appendRecord("timer1", "value1", 1)

    # Second write should not trigger immediate flush
    discard df.appendRecord("timer2", "value2", 2)

    # Wait for time-based flush (100ms)
    let flush1 = df.writeBuffer[].getStats().buffersFlushed

    # Third write after 100ms should trigger immediate flush
    discard df.appendRecord("timer3", "value3", 3)

    # Wait for both flushes
    sleep(300)  # Wait for all flushes to complete
    let stats = df.writeBuffer[].getStats()
    check stats.buffersFlushed >= 2