## Simple Performance Demo
##
## Demonstrates performance options in BitBarrel
##

import os, times, strformat, strutils
import ../src/bitbarrel as barrel

proc sectionHeader(title: string) =
  let line = "─".repeat(title.len + 4)
  echo ""
  echo &"╔" & line & "╗"
  echo "║  " & title & " ║"
  echo "╚" & line & "╝"
  echo ""

proc testSyncModes() =
  sectionHeader("Sync Mode Comparison")

  let testSize = 1000
  echo "  Testing None mode (max performance)..."
  var configNone = barrel.defaultBarrelConfig()
  configNone.syncMode = barrel.UserSyncMode.None
  configNone.writeBufferSize = 128 * 1024

  let db1 = barrel.openBarrel("examples/data/perf_none.dat", configNone)
  let start = cpuTime()
  for i in 0..<testSize:
    discard db1.set(&"key{i}", &"value{i}")
  let timeNone = cpuTime() - start
  db1.close()

  # Test Fsync mode
  echo "  Testing Fsync mode (max durability)..."
  var configFsync = barrel.defaultBarrelConfig()
  configFsync.syncMode = barrel.UserSyncMode.Fsync
  configFsync.writeBufferSize = 128 * 1024

  let db2 = barrel.openBarrel("examples/data/perf_fsync.dat", configFsync)
  let start2 = cpuTime()
  for i in 0..<testSize:
    discard db2.set(&"key2_{i}", &"value2_{i}")
  let timeFsync = cpuTime() - start2
  db2.close()

  # Results
  let opsNone = testSize.float / timeNone
  let opsFsync = testSize.float / timeFsync
  let speedup = opsNone / opsFsync

  echo ""
  echo "Results:"
  echo &"    None mode: {int(opsNone)} ops/sec"
  echo &"  Fsync mode: {int(opsFsync)} ops/sec"
  echo &"  Speedup: {speedup:.1f}x faster"
  echo ""

  # Cleanup
  removeFile("examples/data/perf_none.dat")
  removeFile("examples/data/perf_fsync.dat")

proc testBuffers() =
  sectionHeader("Buffer Size Impact")

  let testSize = 5000

  echo "  Testing 4KB buffer..."
  var cfgSmall = barrel.defaultBarrelConfig()
  cfgSmall.syncMode = barrel.UserSyncMode.None
  cfgSmall.writeBufferSize = 4 * 1024

  let db1 = barrel.openBarrel("examples/data/perf_small.dat", cfgSmall)
  let start = cpuTime()
  for i in 0..<testSize:
    discard db1.set(&"buf_key{i}", &"buf_value{i}")
  let timeSmall = cpuTime() - start
  db1.close()

  echo "  Testing 1MB buffer..."
  var cfgLarge = barrel.defaultBarrelConfig()
  cfgLarge.syncMode = barrel.UserSyncMode.None
  cfgLarge.writeBufferSize = 1024 * 1024

  let db2 = barrel.openBarrel("examples/data/perf_large.dat", cfgLarge)
  let start2 = cpuTime()
  for i in 0..<testSize:
    discard db2.set(&"buf_key{i}", &"buf_value{i}")
  let timeLarge = cpuTime() - start2
  db2.close()

  # Results
  let opsSmall = testSize.float / timeSmall
  let opsLarge = testSize.float / timeLarge
  let speedup = timeSmall / timeLarge

  echo ""
  echo "Results:"
  echo &"    4KB buffer: {int(opsSmall)} ops/sec"
  echo &" 1MB buffer: {int(opsLarge)} ops/sec"
  echo &"  Speedup: {speedup:.1f}x faster"
  echo ""

  # Cleanup
  removeFile("examples/data/perf_small.dat")
  removeFile("examples/data/perf_large.dat")

proc main() =
  echo ""
  echo "╔══════════════════════════════════════════╗"
  echo "║         BitBarrel Performance Demo       ║"
  echo "╚══════════════════════════════════════════╝"
  echo ""
  echo "This demo shows performance impacts of different configurations."
  echo ""

  testSyncModes()
  testBuffers()

  echo ""
  echo "Key takeaways:"
  echo "  • Sync mode has biggest impact on write performance"
  echo "  • Buffer size significantly affects throughput"
  echo ""
  echo "Run 'nimble bench' for comprehensive benchmarking!"

when isMainModule:
  main()