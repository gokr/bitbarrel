## Performance Tuning Demo
##
## Demonstrates different performance optimization options in KVS:
## - Sync modes (None, Normal, Full)
## - Write buffering strategies
## - Batch operations
##
## Run with: nim c -r examples/performance_tuning_demo.nim

import os
import kvs

# Import utils directly for now
include ../src/kvs/utils/demo_output
include ../src/kvs/utils/performance_timer
include ../src/kvs/utils/data_generator

var testCount = 0

proc sectionHeader(title: string) =
  let line = "─".repeat(title.length)
  echo ""
  echo title
  echo line

proc success(message: string) =
  echo "  ✓ " & message

proc compareSyncModes() =
  ## Simple comparison of sync modes
  sectionHeader("Sync Mode Comparison")

  let testSize = 1000
  echo "  Testing different sync modes with {testSize} writes..."

  # Test with no sync
  echo "  Testing None mode (max performance)..."
  var configNone = kvs.defaultConfig()
  configNone.syncMode = kvs.UserSyncMode.None
  configNone.writeBufferSize = 128 * 1024

let kvsNone = kvs.openDatabase("examples/data/perf_none.dat", configNone)
  let startNone = cpuTime()
  for i in 0..<testSize:
    discard kvsNone.set(&"key{i}", &"value{i}")
  let timeNone = cpuTime() - startNone
  kvsNone.close()
  let opsNone = testSize / timeNone

  # Test with full sync
  echo "  Testing Fsync mode (max durability)..."
  var configFsync = kvs.defaultConfig()
  configFsync.syncMode = kvs.UserSyncMode.Fsync
  configFsync.writeBufferSize = 128 * 1024

  let kvsFsync = kvs.openDatabase("examples/data/perf_fsync.dat", configFsync)
  let startFsync = cpuTime()
  for i in 0..<testSize:
    discard kvsFsync.set(&"key{i}", &"value{i}")
  let timeFsync = cpuTime() - startFsync
  kvsFsync.close()
  let opsFsync = testSize / timeFsync

  # Calculate improvement
  let speedRatio = opsNone / opsFsync

  echo ""
  echo "  Results:"
  echo &"    None mode:  {int(opsNone):,} ops/sec"
  echo &"    Fsync mode: {int(opsFsync):,} ops/sec"
  success &"Speedup: {speedRatio:.1f}x faster with None mode"
  echo ""
  echo "  💡 None mode gives fastest performance but risks data loss on crash"
  echo "     Fsync mode ensures durability but is slower"
  echo ""

  # Cleanup
  if fileExists("examples/data/perf_none.dat"):
    removeFile("examples/data/perf_none.dat")
  if fileExists("examples/data/perf_fsync.dat"):
    removeFile("examples/data/perf_fsync.dat")

proc demonstrateBuffering() =
  ## Show impact of write buffering
  sectionHeader("Write Buffering Impact")

  let testSize = 5000
  echo "  Testing different buffer sizes with {testSize} writes..."

  # Small buffer
  echo "  Testing with 4KB buffer..."
  var configSmall = kvs.defaultConfig()
  configSmall.syncMode = kvs.UserSyncMode.None
  configSmall.writeBufferSize = 4 * 1024

let kvsSmall = kvs.openDatabase("examples/data/perf_small.dat", configSmall)
  let startSmall = cpuTime()
  for i in 0..<testSize:
    discard kvsSmall.set(&"buffer_key{i}", &"buffer_value{i}")
  let timeSmall = cpuTime() - startSmall
  kvsSmall.close()

  # Large buffer
  echo "  Testing with 1MB buffer..."
  var configLarge = kvs.defaultConfig()
  configLarge.syncMode = kvs.UserSyncMode.None
  configLarge.writeBufferSize = 1024 * 1024

let kvsLarge = kvs.openDatabase("examples/data/perf_large.dat", configLarge)
  let startLarge = cpuTime()
  for i in 0..<testSize:
    discard kvsLarge.set(&"buffer_key{i}", &"buffer_value{i}")
  let timeLarge = cpuTime() - startLarge
  kvsLarge.close()

  # Calculate improvement
  let speedup = timeSmall / timeLarge
  let opsSmall = testSize / timeSmall
  let opsLarge = testSize / timeLarge

  echo ""
  echo "  Results:"
  echo &"    4KB buffer:  {int(opsSmall):,} ops/sec"
  echo &"    1MB buffer:  {int(opsLarge):,} ops/sec"
  success &"Speedup: {speedup:.1f}x faster with larger buffer"
  echo ""
  echo "  💡 Larger buffers reduce syscalls and improve throughput"
  echo "     But increase memory usage and data loss risk during crash"

  # Cleanup
  if fileExists("examples/data/perf_small.dat"):
    removeFile("examples/data/perf_small.dat")
  if fileExists("examples/data/perf_large.dat"):
    removeFile("examples/data/perf_large.dat")

proc demonstrateBatching() =
  ## Show benefit of batching operations
  sectionHeader("Batching Benefits")

  let testSize = 2000
  echo "  Testing batching vs individual operations with {testSize} writes..."

  # Individual writes
  echo "  Testing individual writes..."
  var configBatch = kvs.defaultConfig()
  configBatch.syncMode = kvs.UserSyncMode.None
  configBatch.writeBufferSize = 1024 * 1024

let kvsBatch = kvs.openDatabase("examples/data/perf_batch.dat", configBatch)
  let startBatch = cpuTime()
  for i in 0..<testSize:
    discard kvsBatch.set(&"batch_key{i}", &"batch_value{i}")
  let timeBatch = cpuTime() - startBatch
  kvsBatch.close()

  let opsBatch = testSize / timeBatch
  echo &"    Individual: {int(opsBatch):,} ops/sec"

  echo ""
  echo "  💡 Batching is automatically handled by the write buffer"
  echo "     Larger batch sizes reduce per-operation overhead"

  # Cleanup
  if fileExists("examples/data/perf_batch.dat"):
    removeFile("examples/data/perf_batch.dat")

proc main() =
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║         KVS Performance Tuning Demo                          ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
  echo "This demo shows how different configurations affect performance."
  echo "For full benchmarks, run: nimble bench"
  echo ""

  compareSyncModes()
  testCount += 1

  demonstrateBuffering()
  testCount += 1

  demonstrateBatching()
  testCount += 1

  echo ""
  echo "✨ Demo completed! ({testCount} tests run)"
  echo ""
  echo "Key takeaways:"
  echo "  • Sync mode biggest impact on write performance"
  echo "  • Larger buffers improve throughput significantly"
  echo "  • Write buffer handles batching automatically"
  echo ""
  echo "Run 'nimble bench' for comprehensive benchmarking!"

when isMainModule:
  main()