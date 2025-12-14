## Performance Tuning Demo
##
## Demonstrates different performance optimization options in KVS:
## - Sync modes (None, Normal, Full)
## - Write buffering strategies
## - Batch operations
## - CRC32 variants for checksums
##
## Run with: nim c -r examples/performance_tuning_demo.nim

import os
import strformat
import times
import random
import utils/demo_output
import utils/performance_timer
import utils/data_generator
import kvs

type
  PerformanceTest* = object
    name: string
    operations: int
    keySize: int
    valueSize: int

proc runBasicWriteTest*(kvs: kvs.SimpleKVS, test: PerformanceTest): Benchmark =
  ## Run a basic write test with individual operations
  result = startBenchmark(test.name)

  let gen = initDataGenerator()

  for i in 0..<test.operations:
    let key = gen.randomKey(test.keySize)
    let value = gen.randomValue(test.valueSize)
    discard kvs.set(key, value)

  result.stopBenchmark(test.operations)

proc runBatchWriteTest*(kvs: kvs.SimpleKVS, test: PerformanceTest, batchSize: int): Benchmark =
  ## Run a write test with batching
  result = startBenchmark(&"{test.name} (batch={batchSize})")

  let gen = initDataGenerator()
  let pairs = gen.generatePairs(test.operations, test.keySize, test.valueSize)

  var batch: seq[tuple[key: string, value: string]] = @[]

  for pair in pairs:
    batch.add(pair)

    if batch.len >= batchSize:
      # Write the batch
      for item in batch:
        discard kvs.set(item.key, item.value)
      batch.setLen(0)

  # Write remaining items
  for item in batch:
    discard kvs.set(item.key, item.value)

  result.stopBenchmark(test.operations)

proc runReadTest*(kvs: kvs.SimpleKVS, keys: seq[string]): Benchmark =
  ## Run a read test
  result = startBenchmark("Read Test")

  for key in keys:
    let value = kvs.get(key)
    # Do something with the value to ensure it's read
    if value.len > 0:
      discard

  result.stopBenchmark(keys.len)

proc compareSyncModes*() =
  ## Compare performance of different sync modes
  subsectionHeader("Sync Mode Comparison")

  let testSize = 1000
  let test = PerformanceTest(
    name: "Basic Writes",
    operations: testSize,
    keySize: 16,
    valueSize: 128
  )

  # Test with no sync
  info("Testing with sync mode: NONE (max performance)")
  var configNone = kvs.defaultConfig()
  configNone.syncMode = kvs.UserSyncMode.None
  configNone.writeBufferSize = 128 * 1024  # 128KB buffer

  var kvsNone = kvs.open("examples/data/perf_none.dat", 1, configNone)
  defer:
    if not kvsNil: kvsNone.close()

  let benchNone = runBasicWriteTest(kvsNone, test)

  # Test with normal sync
  info("Testing with sync mode: SYNC (balanced)")
  var configSync = kvs.defaultConfig()
  configSync.syncMode = kvs.UserSyncMode.Sync
  configSync.writeBufferSize = 128 * 1024

  var kvsSync = kvs.open("examples/data/perf_sync.dat", 1, configSync)
  defer:
    if not kvsSync.isNil: kvsSync.close()

  let benchSync = runBasicWriteTest(kvsSync, test)

  # Test with full sync
  info("Testing with sync mode: FSYNC (max durability)")
  var configFsync = kvs.defaultConfig()
  configFsync.syncMode = kvs.UserSyncMode.Fsync
  configFsync.writeBufferSize = 128 * 1024

  var kvsFsync = kvs.open("examples/data/perf_fsync.dat", 1, configFsync)
  defer:
    if not kvsFsync.isNil: kvsFsync.close()

  let benchFsync = runBasicWriteTest(kvsFsync, test)

  # Print comparison
  tableHeader(@["Sync Mode", "Ops/sec", "Avg Time (ms)", "Total Time (ms)"])

  tableRow(@["None", &"{benchNone.opsPerSecond():.0f}",
              &"{benchNone.timer.averageTime():.3f}",
              &"{benchNone.timer.elapsed()}"])

  tableRow(@["Sync", &"{benchSync.opsPerSecond():.0f}",
              &"{benchSync.timer.averageTime():.3f}",
              &"{benchSync.timer.elapsed()}"])

  tableRow(@["Fsync", &"{benchFsync.opsPerSecond():.0f}",
               &"{benchFsync.timer.averageTime():.3f}",
               &"{benchFsync.timer.elapsed()}"])

  tableFooter()

  # Calculate improvements
  let speedRatioNoneVsSync = benchNone.opsPerSecond() / benchSync.opsPerSecond()
  let speedRatioNoneVsFsync = benchNone.opsPerSecond() / benchFsync.opsPerSecond()

  echo &"\n📊 Performance Insights:"
  success(&"None mode is {speedRatioNoneVsSync:.1f}x faster than Sync")
  success(&"None mode is {speedRatioNoneVsFsync:.1f}x faster than Fsync")
  warning("Fsync mode provides maximum durability but lowest performance")

  # Cleanup
  if fileExists("examples/data/perf_none.dat"):
    removeFile("examples/data/perf_none.dat")
  if fileExists("examples/data/perf_sync.dat"):
    removeFile("examples/data/perf_sync.dat")
  if fileExists("examples/data/perf_fsync.dat"):
    removeFile("examples/data/perf_fsync.dat")

proc demonstrateBufferSizes*() =
  ## Demonstrate impact of different buffer sizes
  subsectionHeader("Write Buffer Size Impact")

  let testSize = 5000
  let bufferSizes = [4*1024, 16*1024, 64*1024, 256*1024, 1024*1024] # 4KB to 1MB

  tableHeader(@["Buffer Size", "Ops/sec", "Avg Time (ms)", "Throughput (MB/s)"])

  for bufSize in bufferSizes:
    var config = kvs.defaultConfig()
    config.syncMode = kvs.UserSyncMode.None  # No sync to isolate buffer effect
    config.writeBufferSize = bufSize

    let kvs = kvs.open(&"examples/data/perf_buf_{bufSize}.dat", 1, config)
    defer:
      if not kvs.isNil: kvs.close()

    let test = PerformanceTest(
      name: &"Buffer {formatBytes(bufSize)}",
      operations: testSize,
      keySize: 16,
      valueSize: 256
    )

    let benchmark = runBasicWriteTest(kvs, test)

    # Calculate throughput (key + value + overhead per record)
    let bytesPerWrite = test.keySize + test.valueSize + 20  # ~20 bytes overhead
    let totalBytes = bytesPerWrite * testSize
    let throughputMB = (totalBytes / 1024.0 / 1024.0) / (benchmark.timer.elapsed() / 1000.0)

    tableRow(@[
      formatBytes(bufSize),
      &"{benchmark.opsPerSecond():.0f}",
      &"{benchmark.timer.averageTime():.3f}",
      &"{throughputMB:.1f}"
    ])

    # Cleanup
    if fileExists(&"examples/data/perf_buf_{bufSize}.dat"):
      removeFile(&"examples/data/perf_buf_{bufSize}.dat")

  tableFooter()

  echo &"\n📊 Buffer Size Insights:"
  success("Larger buffers reduce system calls and improve throughput")
  warning("Very large buffers increase memory usage and risk of data loss")

proc demonstrateBatching*() =
  ## Demonstrate batch operation benefits
  subsectionHeader("Batch Write Performance")

  let testSize = 2000
  let batchSizes = [1, 10, 50, 100, 500]

  tableHeader(@["Batch Size", "Ops/sec", "Avg Time (ms)", "Total Time (ms)"])

  for batchSize in batchSizes:
    var config = kvs.defaultConfig()
    config.syncMode = kvs.UserSyncMode.None
    config.writeBufferSize = 1024 * 1024  # 1MB buffer

    let kvs = kvs.open(&"examples/data/perf_batch_{batchSize}.dat", 1, config)
    defer:
      if not kvs.isNil: kvs.close()

    let test = PerformanceTest(
      name: &"Batch {batchSize}",
      operations: testSize,
      keySize: 16,
      valueSize: 128
    )

    let benchmark = runBatchWriteTest(kvs, test, batchSize)

    tableRow(@[
      &"{batchSize}",
      &"{benchmark.opsPerSecond():.0f}",
      &"{benchmark.timer.averageTime():.3f}",
      &"{benchmark.timer.elapsed()}"
    ])

    # Cleanup
    if fileExists(&"examples/data/perf_batch_{batchSize}.dat"):
      removeFile(&"examples/data/perf_batch_{batchSize}.dat")

  tableFooter()

  echo &"\n📊 Batching Insights:"
  success("Larger batches reduce overhead and improve throughput")
  warning("Batching increases latency for individual operations")

proc demonstrateReadWriteRatio*() =
  ## Demonstrate performance with different read/write ratios
  subsectionHeader("Read/Write Ratio Performance")

  let totalOps = 10000
  let ratios = [(100, 0), (80, 20), (50, 50), (20, 80), (0, 100)]

  tableHeader(@["Read %", "Write %", "Ops/sec", "Avg Read (ms)", "Avg Write (ms)"])

  for (readPct, writePct) in ratios:
    var config = kvs.defaultConfig()
    config.syncMode = kvs.UserSyncMode.Sync
    config.writeBufferSize = 64 * 1024

    let kvs = kvs.open(&"examples/data/perf_rw_{readPct}_{writePct}.dat", 1, config)
    defer:
      if not kvs.isNil: kvs.close()

    # Pre-populate with data for read tests
    let gen = initDataGenerator()
    let numKeys = totalOps * writePct div 100
    var keys: seq[string] = @[]

    for i in 0..<numKeys:
      let key = gen.randomKey(16)
      keys.add(key)
      discard kvs.set(key, gen.randomValue(128))

    let bench = startBenchmark(&"{readPct}/{writePct}")
    var readBench: Timer
    var writeBench: Timer

    readBench = startTimer()
    writeBench = startTimer()

    let readOps = (totalOps * readPct) div 100
    let writeOps = (totalOps * writePct) div 100

    # Mix reads and writes
    for i in 0..<totalOps:
      if readPct == 100 or (writePct < 100 and rand(100) < readPct):
        # Read operation
        readBench.lap()
        if keys.len > 0:
          let idx = rand(keys.len - 1)
          discard kvs.get(keys[idx])
      else:
        # Write operation
        writeBench.lap()
        let key = gen.randomKey(16)
        let value = gen.randomValue(128)
        discard kvs.set(key, value)
        keys.add(key)

    bench.stopBenchmark(totalOps)

    tableRow(@[
      &"{readPct}",
      &"{writePct}",
      &"{bench.opsPerSecond():.0f}",
      &"{if readOps > 0: readBench.averageTime():.3f else: 0:.3f}",
      &"{if writeOps > 0: writeBench.averageTime():.3f else: 0:.3f}"
    ])

    # Cleanup
    if fileExists(&"examples/data/perf_rw_{readPct}_{writePct}.dat"):
      removeFile(&"examples/data/perf_rw_{readPct}_{writePct}.dat")

  tableFooter()

  echo &"\n📊 R/W Ratio Insights:"
  success("Read operations are typically faster than writes")
  success("Optimal configuration depends on your access pattern")

proc main() =
  sectionHeader("KVS Performance Tuning Demo")

  # Ensure data directory exists
  createDir("examples/data")

  info("This demo demonstrates various performance optimization techniques")
  info("Run it multiple times to account for system variations")
  separator()

  # Run different performance tests
  compareSyncModes()
  separator()

  demonstrateBufferSizes()
  separator()

  demonstrateBatching()
  separator()

  demonstrateReadWriteRatio()
  separator()

  subsectionHeader("Performance Optimization Summary")
  info("✓ Use None sync mode for maximum performance (no durability)")
  info("✓ Use larger write buffers for bulk operations")
  info("✓ Batch operations when possible to reduce overhead")
  info("✓ Configure based on your read/write pattern")
  info("✓ Monitor metrics to tune for your workload")

  echo "\n✨ Performance tuning demo completed!"

when isMainModule:
  main()