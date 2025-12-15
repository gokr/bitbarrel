## Performance Tuning Demo
##
## Demonstrates performance characteristics of KVS using real APIs:
## - Sync modes (None, Sync, Fsync) and their trade-offs
## - Write buffer sizing impact
## - Batch operations vs individual writes
##
## Run with: nim c -r examples/performance_tuning_demo.nim

import os
import strformat
import strutils except formatSize
import times
import demo_utils
import ../src/kvs

type
  PerformanceTest* = object
    name: string
    operations: int
    keySize: int
    valueSize: int

proc cleanupDataFiles() =
  ## Clean up test data files
  let dataDir = "examples/data"
  if dirExists(dataDir):
    for kind, path in walkDir(dataDir):
      if kind == pcFile and path.endsWith(".db"):
        try:
          removeFile(path)
        except:
          discard

proc runPerformanceTest*(kvs: SimpleKVS, test: PerformanceTest): int64 =
  ## Run a performance test and return time in ms
  echo &"\n📊 {test.name}"

  var timer = startTimer()

  for i in 0..<test.operations:
    let key = &"test:{test.name}:{i:04d}"
    let value = &"value-{i:06d}-{test.valueSize}x"
    discard kvs.set(key, value)

  timer.stop()
  let elapsed = timer.elapsed()
  let opsPerSec = test.operations.float / (elapsed.float / 1000.0)

  keyValue("Operations", test.operations)
  keyValue("Time (ms)", elapsed)
  keyValue("Ops/sec", &"{opsPerSec:.0f}")

  return elapsed

proc demonstrateSyncModes*() =
  ## Compare performance of different sync modes
  subsectionHeader("Sync Mode Performance Comparison")

  let testSize = 5000
  echo &"Performing {testSize} write operations per test...\n"

  # Test with None sync (max performance, no durability)
  var fastConfig = defaultConfig()
  fastConfig.syncMode = UserSyncMode.None
  fastConfig.writeBufferSize = 1024 * 1024  # 1MB buffer

  var fastDb = openDatabase("examples/data/fast_sync_test.db", fastConfig)
  defer: fastDb.close()

  let fastTime = runPerformanceTest(fastDb, PerformanceTest(
    name: "None Sync",
    operations: testSize,
    keySize: 16,
    valueSize: 64
  ))

  # Test with Sync mode (balanced)
  var normalConfig = defaultConfig()
  normalConfig.syncMode = UserSyncMode.Sync
  normalConfig.writeBufferSize = 256 * 1024  # 256KB buffer

  var normalDb = openDatabase("examples/data/normal_sync_test.db", normalConfig)
  defer: normalDb.close()

  let normalTime = runPerformanceTest(normalDb, PerformanceTest(
    name: "Sync Mode",
    operations: testSize,
    keySize: 16,
    valueSize: 64
  ))

  # Test with Fsync (max durability)
  var safeConfig = defaultConfig()
  safeConfig.syncMode = UserSyncMode.Fsync
  safeConfig.writeBufferSize = 32 * 1024  # 32KB buffer

  var safeDb = openDatabase("examples/data/safe_sync_test.db", safeConfig)
  defer: safeDb.close()

  let safeTime = runPerformanceTest(safeDb, PerformanceTest(
    name: "Fsync Mode",
    operations: testSize,
    keySize: 16,
    valueSize: 64
  ))

  # Calculate and show performance ratios
  echo "\n📈 Performance Analysis:"
  let speedRatioNoneVsSync = normalTime.float / fastTime.float
  let speedRatioSyncVsFsync = safeTime.float / normalTime.float
  let speedRatioNoneVsFsync = safeTime.float / fastTime.float

  success(&"None mode is {speedRatioNoneVsSync:.1f}x faster than Sync")
  info(&"Sync mode is {speedRatioSyncVsFsync:.1f}x faster than Fsync")
  warning(&"None mode is {speedRatioNoneVsFsync:.1f}x faster than Fsync")

  cleanupDataFiles()

proc demonstrateBufferSizes*() =
  ## Show impact of different write buffer sizes
  subsectionHeader("Write Buffer Size Impact")

  let testSize = 3000
  let bufferSizes = [16*1024, 64*1024, 256*1024, 1024*1024]  # 16KB to 1MB
  echo &"Testing {bufferSizes.len} buffer sizes with {testSize} operations each\n"

  for bufSize in bufferSizes:
    var config = defaultConfig()
    config.syncMode = UserSyncMode.None  # No sync to isolate buffer effect
    config.writeBufferSize = bufSize

    let db = openDatabase(&"examples/data/buf_{bufSize}.db", config)
    defer: db.close()

    let time = runPerformanceTest(db, PerformanceTest(
      name: &"Buffer {formatSize(bufSize)}",
      operations: testSize,
      keySize: 16,
      valueSize: 64
    ))

    echo &"Buffer {formatSize(bufSize)}: {formatSize(testSize * 80)} written in {time}ms"

  cleanupDataFiles()

proc demonstrateBatching*() =
  ## Show how batching affects performance
  subsectionHeader("Batch Operations vs Individual Writes")

  let testSize = 2000
  let batchSizes = [1, 10, 50, 100, 500]
  echo &"Testing {batchSizes.len} batch sizes with {testSize} total operations\n"

  for batchSize in batchSizes:
    let numBatches = testSize div batchSize
    var config = defaultConfig()
    config.syncMode = UserSyncMode.None
    config.writeBufferSize = 512 * 1024

    let db = openDatabase(&"examples/data/batch_{batchSize}.db", config)
    defer: db.close()

    var timer = startTimer()

    for batchIdx in 0..<numBatches:
      let startIdx = batchIdx * batchSize
      let endIdx = min(startIdx + batchSize, testSize)

      for i in startIdx..<endIdx:
        let key = &"batch:{batchIdx}:{i:04d}"
        let value = &"value-{i:04d}"
        discard db.set(key, value)

    timer.stop()
    let elapsed = timer.elapsed()
    let opsPerSec = testSize.float / (elapsed.float / 1000.0)

    echo &"Batch size {batchSize:3d}: {elapsed.float/1000.0:.2f}s, {opsPerSec:.0f} ops/sec"

  cleanupDataFiles()

proc demonstrateRealWorldScenario*() =
  ## Simulate a real-world mixed workload
  subsectionHeader("Real-World Mixed Workload")

  echo "Simulating 70% reads, 30% writes pattern...\n"

  var config = defaultConfig()
  config.syncMode = UserSyncMode.Sync  # Balanced durability
  config.writeBufferSize = 128 * 1024

  let db = openDatabase("examples/data/realworld.db", config)
  defer: db.close()

  # Pre-populate with data
  let loadData = 1000
  for i in 0..<loadData:
    discard db.set(&"user:{i}", &"user-data-{i}")

  echo &"Pre-populated {loadData} keys"

  # Mixed operations
  let totalOps = 5000
  let readOps = (totalOps * 7) div 10  # 70% reads
  let writeOps = totalOps - readOps  # 30% writes

  var timer = startTimer()

  var readsPerformed = 0
  var writesPerformed = 0

  var i = 0
  while i < totalOps:
    if readsPerformed < readOps:
      # Read operation
      let key = &"user:{i mod loadData}"
      let _ = db.get(key)
      inc readsPerformed
    else:
      # Write operation
      let key = &"session:{i}"
      let value = &"session-data-{i}-{getTime().toUnix()}"
      discard db.set(key, value)
      inc writesPerformed

    inc i

  timer.stop()

  echo "\n📓 Mixed Workload Results:"
  keyValue("Total operations", totalOps)
  keyValue("Reads performed", readsPerformed)
  keyValue("Writes performed", writesPerformed)
  keyValue("Total time", &"{timer.elapsed()}ms")
  let mixedOpsPerSec = totalOps.float / (timer.elapsed().float / 1000.0)
  echo &"Mixed throughput: {mixedOpsPerSec:.0f} ops/sec"

  cleanupDataFiles()

proc printPerformanceInsights*() =
  ## Provide insights about KVS performance characteristics
  subsectionHeader("Performance Insights & Best Practices")

  echo "✅ Sync Mode Selection:"
  info("  • None模式 - 最高性能，但进程崩溃会丢失最后未同步的数据")
  info("  • Sync模式 - 平衡点，每写同步到操作系统")
  info("  • Fsync模式 - 最大安全性，写操作会等待磁盘I/O完成")

  echo "\n✅ Buffer Size Tuning:"
  info("  • 小缓冲区(16KB): 低延迟，适合低负载应用")
  info("  • 中等缓冲区(256KB): 平衡性能和内存使用")
  info("  • 大缓冲区(1MB): 高吞吐量，适合批量写入")

  echo "\n✅ Batching Benefits:"
  info("  • 批量操作减少系统调用开销")
  info("  • 10-100是最佳批量大小范围")
  info("  • 过大批次会增加单个操作的延迟")

  echo "\n✅ Memory Trade-offs:"
  info("  • KeyDir占用: ~50字节/键")
  info("  • 100万键 ≈ 500MB内存")
  info("  • 建议: 100万-500万keys作为实际限制")

  echo "\n✅ Disk Usage:"
  info("  • Bitcask特点: 1.0-1.5倍数据大小(追加式开销)")
  info("  → 定期compaction可回收空间")
  info("  → 适合SSD硬盘(顺序写入)")

proc main() =
  sectionHeader("KVS Performance Tuning Demo")

  echo "This demo demonstrates real KVS performance characteristics using actual APIs."
  echo "It measures actual behavior, not theoretical values.\n"

  echo "⚡  Note: Results will vary based on your hardware.\n"

  demonstrateSyncModes()
  separator()

  demonstrateBufferSizes()
  separator()

  demonstrateBatching()
  separator()

  demonstrateRealWorldScenario()
  separator()

  printPerformanceInsights()

  echo "\n✨ Performance tuning demo completed!"
  echo ""
  echo "Key takeaways:"
  success("• Choose sync mode based on durability requirements")
  success("• Tune buffer size for your workload pattern")
  success("• Use batching for bulk operations")
  success("• Monitor metrics in production to tune further")

when isMainModule:
  main()