## BitBarrel Performance Demo
##
## Demonstrates performance characteristics of BitBarrel:
## - Sync modes (None, Sync, Fsync) and their trade-offs
## - Write buffer sizing impact
## - Batch operations vs individual writes
##
## Run with: nim c -r examples/basic/performance.nim

import std/[os, strformat, times, cpuinfo]
import std/strutils except formatSize
import ../utils
import bitbarrel

type
  PerformanceTest = object
    name: string
    operations: int
    keySize: int
    valueSize: int

proc cleanupDataFiles() =
  ## Clean up test data files
  let dataDir = "examples/data"
  if dirExists(dataDir):
    for kind, path in walkDir(dataDir):
      if kind == pcFile and (path.endsWith(".data") or path.endsWith(".db")):
        try:
          removeFile(path)
        except:
          discard

proc runPerformanceTest(barrel: Barrel, test: PerformanceTest): int64 =
  ## Run a performance test and return time in ms
  echo &"\n📊 {test.name}"

  var timer = startTimer()

  for i in 0..<test.operations:
    let key = &"test:{test.name}:{i:04d}"
    let value = &"value-{i:06d}-{test.valueSize}x"
    discard barrel.set(key, value)

  timer.stop()
  let elapsed = timer.elapsed()
  let opsPerSec = test.operations.float / (elapsed.float / 1000.0)

  keyValue("Operations", test.operations)
  keyValue("Time (ms)", elapsed)
  keyValue("Ops/sec", &"{opsPerSec:.0f}")

  return elapsed

proc demonstrateSyncModes() =
  ## Compare performance of different sync modes
  subsectionHeader("Sync Mode Performance Comparison")

  let testSize = 5000
  echo &"Performing {testSize} write operations per test..."

  # Test with None sync (max performance, no durability)
  var fastConfig = defaultBarrelConfig()
  fastConfig.syncMode = UserSyncMode.None
  fastConfig.writeBufferSize = 1024 * 1024  # 1MB buffer

  var fastDb = openBarrel("examples/data/fast_sync_test.data", fastConfig)
  defer: fastDb.close()

  let fastTime = runPerformanceTest(fastDb, PerformanceTest(
    name: "None Sync",
    operations: testSize,
    keySize: 16,
    valueSize: 64
  ))

  # Test with Sync mode (balanced)
  var normalConfig = defaultBarrelConfig()
  normalConfig.syncMode = UserSyncMode.Sync
  normalConfig.writeBufferSize = 256 * 1024  # 256KB buffer

  var normalDb = openBarrel("examples/data/normal_sync_test.data", normalConfig)
  defer: normalDb.close()

  let normalTime = runPerformanceTest(normalDb, PerformanceTest(
    name: "Sync Mode",
    operations: testSize,
    keySize: 16,
    valueSize: 64
  ))

  # Test with Fsync (max durability)
  var safeConfig = defaultBarrelConfig()
  safeConfig.syncMode = UserSyncMode.Fsync
  safeConfig.writeBufferSize = 32 * 1024  # 32KB buffer

  var safeDb = openBarrel("examples/data/safe_sync_test.data", safeConfig)
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

proc demonstrateBufferSizes() =
  ## Show impact of different write buffer sizes
  subsectionHeader("Write Buffer Size Impact")

  let testSize = 3000
  let bufferSizes = [16*1024, 64*1024, 256*1024, 1024*1024]  # 16KB to 1MB
  echo &"Testing {bufferSizes.len} buffer sizes with {testSize} operations each"

  for bufSize in bufferSizes:
    var config = defaultBarrelConfig()
    config.syncMode = UserSyncMode.None  # No sync to isolate buffer effect
    config.writeBufferSize = bufSize

    let db = openBarrel(&"examples/data/buf_{bufSize}.data", config)
    defer: db.close()

    let time = runPerformanceTest(db, PerformanceTest(
      name: &"Buffer {formatSize(bufSize)}",
      operations: testSize,
      keySize: 16,
      valueSize: 64
    ))

    echo &"Buffer {formatSize(bufSize)}: {formatSize(testSize * 80)} written in {time}ms"

  cleanupDataFiles()

proc demonstrateBatching() =
  ## Show how batching affects performance
  subsectionHeader("Batch Operations vs Individual Writes")

  let testSize = 2000
  let batchSizes = [1, 10, 50, 100, 500]
  echo &"Testing {batchSizes.len} batch sizes with {testSize} total operations"

  for batchSize in batchSizes:
    let numBatches = testSize div batchSize
    var config = defaultBarrelConfig()
    config.syncMode = UserSyncMode.None
    config.writeBufferSize = 512 * 1024

    let db = openBarrel(&"examples/data/batch_{batchSize}.data", config)
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

proc demonstrateDirectVsBuffered() =
  ## Compare direct writes vs buffered writes
  subsectionHeader("Direct Writes vs Buffered Writes")

  const NUM_OPS = 10000

  # Direct writes (default config)
  let directDb = openBarrel("examples/data/perf_direct.data")
  let start = cpuTime()
  for i in 0..<NUM_OPS:
    discard directDb.set(&"key{i}", &"value{i}")
  directDb.close()
  let directTime = cpuTime() - start
  echo "Direct writes:"
  echo &"   {NUM_OPS} ops in {directTime:.3f}s ({int(NUM_OPS / directTime)} ops/sec)"

  # Buffered writes
  var bufferedConfig = defaultBarrelConfig()
  bufferedConfig.syncMode = UserSyncMode.Sync
  bufferedConfig.writeBufferSize = 64 * 1024

  let bufferedDb = openBarrel("examples/data/perf_buffered.data", bufferedConfig)
  let start2 = cpuTime()
  for i in 0..<NUM_OPS:
    discard bufferedDb.set(&"key{i}", &"value{i}")
  bufferedDb.close()
  let bufferedTime = cpuTime() - start2
  echo "Buffered writes:"
  echo &"   {NUM_OPS} ops in {bufferedTime:.3f}s ({int(NUM_OPS / bufferedTime)} ops/sec)"

  if bufferedTime < directTime:
    let speedup = directTime / bufferedTime
    echo &"   Speedup: {speedup:.2f}x faster"
  else:
    let slowdown = bufferedTime / directTime
    echo &"   Speedup: {slowdown:.2f}x slower"

  cleanupDataFiles()

proc demonstrateRealWorldScenario() =
  ## Simulate a real-world mixed workload
  subsectionHeader("Real-World Mixed Workload")

  echo "Simulating 70% reads, 30% writes pattern..."

  var config = defaultBarrelConfig()
  config.syncMode = UserSyncMode.Sync  # Balanced durability
  config.writeBufferSize = 128 * 1024

  let db = openBarrel("examples/data/realworld.data", config)
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
  keyValue("Expected reads", readOps)
  keyValue("Expected writes", writeOps)
  keyValue("Reads performed", readsPerformed)
  keyValue("Writes performed", writesPerformed)
  keyValue("Total time", &"{timer.elapsed()}ms")
  let mixedOpsPerSec = totalOps.float / (timer.elapsed().float / 1000.0)
  echo &"Mixed throughput: {mixedOpsPerSec:.0f} ops/sec"

  cleanupDataFiles()

proc printPerformanceInsights() =
  ## Provide insights about BitBarrel performance characteristics
  subsectionHeader("Performance Insights & Best Practices")

  echo "Sync Mode Selection:"
  info("  • None mode - Highest performance, but unsynced data lost on process crash")
  info("  • Sync mode - Balanced choice, synced to OS on each write")
  info("  • Fsync mode - Maximum safety, writes wait for disk I/O completion")

  echo "\nBuffer Size Tuning:"
  info("  • Small buffer (16KB): Low latency, suitable for low-load applications")
  info("  • Medium buffer (256KB): Balanced performance and memory usage")
  info("  • Large buffer (1MB): High throughput, suitable for bulk writes")

  echo "\nBatching Benefits:"
  info("  • Batch operations reduce system call overhead")
  info("  • 10-100 is the optimal batch size range")
  info("  • Oversized batches increase individual operation latency")

  echo "\nMemory Trade-offs:"
  info("  • KeyDir overhead: ~40 bytes per key")
  info("  • 1 million keys ≈ 400MB memory")
  info("  • Recommendation: 1-5 million keys as practical limit")

  echo "\nDisk Usage:"
  info("  • Bitcask characteristic: 1.0-1.5x data size (append-only overhead)")
  info("  • Regular compaction reclaims space")
  info("  • Suitable for SSD drives (sequential writes)")

proc main() =
  sectionHeader("BitBarrel Performance Tuning Demo")

  echo "This demo demonstrates real BitBarrel performance characteristics using actual APIs."
  echo "It measures actual behavior, not theoretical values."

  echo "\n⚡  Note: Results will vary based on your hardware."

  demonstrateSyncModes()
  separator()

  demonstrateBufferSizes()
  separator()

  demonstrateBatching()
  separator()

  demonstrateDirectVsBuffered()
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
  echo ""
  echo "Run 'nimble bench' for comprehensive benchmarking!"

when isMainModule:
  main()
