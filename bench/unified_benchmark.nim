## Unified BitBarrel Benchmark Suite
##
## Comprehensive benchmark testing for all UserSyncMode options and configurations
## Usage: unified_benchmark [quick|standard|comprehensive]

import os, times, strformat, math, strutils, sugar, sequtils, random
import ../src/bitbarrel
from ../src/bitbarrel/types import BarrelMode

type
  BenchmarkResult = object
    name: string
    opsPerSec: float
    avgLatency: float
    totalTime: float
    mode: string
    bufferMode: string

  BenchmarkProfile = object
    name: string
    operations: int
    syncModes: seq[UserSyncMode]
    bufferSizes: seq[int]

  BenchmarkConfig = object
    profile: BenchmarkProfile
    keySize: int
    valueSize: int

const
  QUICK_PROFILE = BenchmarkProfile(
    name: "Quick",
    operations: 1000,
    syncModes: @[UserSyncMode.None, UserSyncMode.Fsync],
    bufferSizes: @[64 * 1024]
  )

  STANDARD_PROFILE = BenchmarkProfile(
    name: "Standard",
    operations: 10000,
    syncModes: @[UserSyncMode.None, UserSyncMode.Sync, UserSyncMode.Fsync],
    bufferSizes: @[4 * 1024, 64 * 1024, 256 * 1024]
  )

  COMPREHENSIVE_PROFILE = BenchmarkProfile(
    name: "Comprehensive",
    operations: 100000,
    syncModes: @[UserSyncMode.None, UserSyncMode.Sync, UserSyncMode.Fsync],
    bufferSizes: @[4 * 1024, 16 * 1024, 64 * 1024, 256 * 1024, 1024 * 1024]
  )

proc printHeader(title: string) =
  let line = "=".repeat(60)
  echo line
  echo "  " & title
  echo line
  echo ""

proc printTableHeader(columns: openArray[string]) =
  let totalWidth = sum(columns.mapIt(it.len + 3))
  echo "  " & "─".repeat(totalWidth)
  for i, col in columns:
    let padding = 3 - col.len mod 2
    echo "│ " & col & " ".repeat(padding) & " "
  echo "├" & "─".repeat(totalWidth)

proc printTableRow(values: openArray[string]) =
  for i, val in values:
    let padding = 3 - val.len mod 2
    echo "│ " & val & " ".repeat(padding) & " "

proc printTableFooter(width: int) =
  echo "└" & "─".repeat(width)

proc runWriteBenchmark(config: BenchmarkConfig, syncMode: UserSyncMode, bufferSize: int): BenchmarkResult =
  let dbFile = "bench_unified_test.dat"
  var cfg = defaultConfig()
  cfg.syncMode = syncMode
  cfg.writeBufferSize = bufferSize

  let bb = openDatabase(dbFile, cfg)

  let start = cpuTime()

  for i in 0..<config.profile.operations:
    let key = "key_" & $i
    let value = "value_" & $i
    discard bb.set(key, value)

  let totalTime = cpuTime() - start
  bb.close()
  removeFile(dbFile)

  result = BenchmarkResult(
    name: config.profile.name & " - " & $syncMode,
    opsPerSec: config.profile.operations.float / totalTime,
    avgLatency: (totalTime * 1000) / config.profile.operations.float,
    totalTime: totalTime * 1000,
    mode: $syncMode,
    bufferMode: $(bufferSize div 1024) & "KB"
  )

proc testSyncModes(config: BenchmarkConfig) =
  printHeader("Sync Mode Performance Test")

  let columns = ["Sync Mode", "Ops/sec", "Avg Latency (ms)", "Total Time (ms)"]
  printTableHeader(columns)

  var fastestResult: BenchmarkResult
  fastestResult.opsPerSec = -1

  for syncMode in config.profile.syncModes:
    let result = runWriteBenchmark(config, syncMode, config.profile.bufferSizes[0])

    if result.opsPerSec > fastestResult.opsPerSec:
      fastestResult = result

    printTableRow([result.mode, $int(result.opsPerSec),
                   &"{result.avgLatency:.3f}", $int(result.totalTime)])

  printTableFooter(sum(columns.mapIt(it.len + 3)))
  echo ""
  echo &"🏆 Fast sync mode: {fastestResult.mode} ({int(fastestResult.opsPerSec)} ops/sec)"
  echo ""

proc testBufferSizes(config: BenchmarkConfig) =
  printHeader("Buffer Size Impact Test")

  let columns = ["Buffer Size", "Ops/sec", "Avg Latency (ms)", "Total Time (ms)"]
  printTableHeader(columns)

  var bestResult: BenchmarkResult
  bestResult.opsPerSec = -1

  for bufSize in config.profile.bufferSizes:
    let result = runWriteBenchmark(config, UserSyncMode.None, bufSize)

    if result.opsPerSec > bestResult.opsPerSec:
      bestResult = result

    printTableRow([result.bufferMode, $int(result.opsPerSec),
                   &"{result.avgLatency:.3f}", $int(result.totalTime)])

  printTableFooter(sum(columns.mapIt(it.len + 3)))
  echo ""
  echo &"🏆 Best buffer size: {bestResult.bufferMode} ({int(bestResult.opsPerSec)} ops/sec)"
  echo ""

proc testReadPerformance(): BenchmarkResult =
  printHeader("Read Performance Test")

  let dbFile = "bench_unified_read_test.dat"
  let bb = openDatabase(dbFile)

  # Write test data first
  let numKeys = 10000
  for i in 0..<numKeys:
    let key = "read_key_" & $i
    let value = "value_" & $i
    discard bb.set(key, value)

  # Now read performance
  let keys = (0..<numKeys).mapIt("read_key_" & $it)

  let start = cpuTime()
  for key in keys:
    let value = bb.get(key)
    discard value.len  # Ensure read
  let totalTime = cpuTime() - start

  bb.close()
  removeFile(dbFile)

  result = BenchmarkResult(
    name: "Read Test",
    opsPerSec: numKeys.float / totalTime,
    avgLatency: (totalTime * 1000) / numKeys.float,
    totalTime: totalTime * 1000,
    mode: "N/A",
    bufferMode: "N/A"
  )

  echo &"Read Performance:"
  echo &"  Operations: {numKeys}"
  echo &"  Throughput: {int(result.opsPerSec)} ops/sec"
  echo &"  Average Latency: {result.avgLatency:.3f} ms"
  echo ""

proc testMixedWorkload(config: BenchmarkConfig): BenchmarkResult =
  printHeader("Mixed Workload Test (80% Read / 20% Write)")

  let dbFile = "bench_unified_mixed.dat"
  let bb = openDatabase(dbFile)

  let readRatio = 0.8
  let writeOps = int(config.profile.operations.float * (1 - readRatio))
  let readOps = config.profile.operations - writeOps

  # Seed initial data
  for i in 0..<readOps:
    let key = "mixed_key_" & $i
    let value = "value_" & $i
    discard bb.set(key, value)

  let start = cpuTime()

  var readsDone = 0
  var writesDone = 0

  var i = 0
  while i < config.profile.operations:
    if rand(1.0) < readRatio:
      # Read operation
      let key = "mixed_key_" & $(i mod readOps)
      let value = bb.get(key)
      discard value.len
      readsDone += 1
    else:
      # Write operation
      let key = "mixed_write_" & $i
      let value = "write_value_" & $i
      discard bb.set(key, value)
      writesDone += 1
    i += 1

  let totalTime = cpuTime() - start
  bb.close()
  removeFile(dbFile)

  result = BenchmarkResult(
    name: "Mixed Workload",
    opsPerSec: config.profile.operations.float / totalTime,
    avgLatency: (totalTime * 1000) / config.profile.operations.float,
    totalTime: totalTime * 1000,
    mode: "Mixed",
    bufferMode: &"R:{readOps} W:{writesDone}"
  )

  echo &"Mixed Workload Results:"
  echo &"  Total Operations: {config.profile.operations}"
  echo &"  Read Operations: {readsDone} ({readRatio * 100:.0f}%)"
  echo &"  Write Operations: {writesDone} ({(1-readRatio) * 100:.0f}%)"
  echo &"  Overall Throughput: {int(result.opsPerSec)} ops/sec"
  echo &"  Average Latency: {result.avgLatency:.3f} ms"
  echo ""

proc testBarrelModes(config: BenchmarkConfig) =
  printHeader("Barrel Modes Comparison")

  let columns = ["Mode", "Ops/sec", "Avg Latency (ms)", "Total Time (ms)", "Notes"]
  printTableHeader(columns)

  var bestResult: BenchmarkResult
  bestResult.opsPerSec = -1

  # Test bmHash mode
  let dbFileNormal = "bench_mode_normal.dat"
  var cfgNormal = defaultConfig()
  cfgNormal.mode = BarrelMode.bmHash
  var bbNormal = openDatabase(dbFileNormal, cfgNormal)

  let startNormal = cpuTime()
  for i in 0..<config.profile.operations:
    let key = "key_" & $i
    let value = "value_" & $i
    discard bbNormal.set(key, value)
  let timeNormal = cpuTime() - startNormal
  bbNormal.close()
  removeFile(dbFileNormal)

  let normalResult = BenchmarkResult(
    name: "Normal Mode",
    opsPerSec: config.profile.operations.float / timeNormal,
    avgLatency: (timeNormal * 1000) / config.profile.operations.float,
    totalTime: timeNormal * 1000,
    mode: "bmHash",
    bufferMode: "O(1) hash"
  )

  if normalResult.opsPerSec > bestResult.opsPerSec:
    bestResult = normalResult

  printTableRow([normalResult.mode, $int(normalResult.opsPerSec),
                 &"{normalResult.avgLatency:.3f}", $int(normalResult.totalTime),
                 "Hash table, simplest"])

  # Test bmCritBit mode
  let dbFileCritBit = "bench_mode_critbit.dat"
  var cfgCritBit = defaultConfig()
  cfgCritBit.mode = BarrelMode.bmCritBit
  var bbCritBit = openDatabase(dbFileCritBit, cfgCritBit)

  let startCritBit = cpuTime()
  for i in 0..<config.profile.operations:
    let key = "key_" & $i
    let value = "value_" & $i
    discard bbCritBit.set(key, value)
  let timeCritBit = cpuTime() - startCritBit
  bbCritBit.close()
  removeFile(dbFileCritBit)

  let critBitResult = BenchmarkResult(
    name: "CritBit Mode",
    opsPerSec: config.profile.operations.float / timeCritBit,
    avgLatency: (timeCritBit * 1000) / config.profile.operations.float,
    totalTime: timeCritBit * 1000,
    mode: "bmCritBit",
    bufferMode: "O(k) tree"
  )

  if critBitResult.opsPerSec > bestResult.opsPerSec:
    bestResult = critBitResult

  printTableRow([critBitResult.mode, $int(critBitResult.opsPerSec),
                 &"{critBitResult.avgLatency:.3f}", $int(critBitResult.totalTime),
                 "Ordered, range queries"])

  # Note: bmRanged mode is not currently implemented
  # Future design: See docs/research/HUGECRITBIT.md for proposed billion-key support

  printTableFooter(sum(columns.mapIt(it.len + 3)))
  echo ""
  echo &"🏆 Best barrel mode: {bestResult.mode} ({int(bestResult.opsPerSec)} ops/sec)"
  echo ""
  echo "Note: bmHash is fastest for simple lookups"
  echo "      bmCritBit supports range queries and prefix searches"
  echo ""

proc printSummary(results: seq[BenchmarkResult]) =
  printHeader("Benchmark Summary")

  if results.len == 0:
    echo "No results to display"
    return

  echo &"Profile: {results[0].name}"
  echo &"Test Operations: {STANDARD_PROFILE.operations}"
  echo ""

  for result in results:
    if result.name != "Read Test" and result.name != "Mixed Workload":
      echo &"  {result.name}: {int(result.opsPerSec)} ops/sec ({result.totalTime:.0f}ms)"

  echo ""

proc main() =
  randomize()

  # Parse command line arguments
  var profile = STANDARD_PROFILE
  if paramCount() > 0:
    case paramStr(1)
    of "quick":
      profile = QUICK_PROFILE
    of "standard":
      profile = STANDARD_PROFILE
    of "comprehensive":
      profile = COMPREHENSIVE_PROFILE
    else:
      echo "Unknown profile. Using standard."
      echo "Usage: unified_benchmark [quick|standard|comprehensive]"
      echo ""

  let config = BenchmarkConfig(
    profile: profile,
    keySize: 16,
    valueSize: 64
  )

  echo ""
  echo "============================================================"
  echo "                BitBarrel Unified Benchmark Suite"
  echo "============================================================"
  echo ""
  echo &"Profile: {profile.name}"
  echo &"Operations per test: {profile.operations}"
  echo &"Sync modes to test: {profile.syncModes.len}"
  echo &"Buffer sizes to test: {profile.bufferSizes.len}"
  echo ""

  let startAll = cpuTime()
  var allResults: seq[BenchmarkResult] = @[]

  # Run tests
  testSyncModes(config)
  testBufferSizes(config)
  testBarrelModes(config)
  let readResult = testReadPerformance()
  allResults.add(readResult)
  let mixedResult = testMixedWorkload(config)
  allResults.add(mixedResult)

  let totalTime = cpuTime() - startAll

  printHeader("Benchmark Complete")
  echo &"Total time: {totalTime:.2f} seconds"
  echo ""

  printSummary(allResults)

  echo "✨ Benchmark completed successfully!"
  echo "  Run 'nimble benchQuick' for quick tests"
  echo "  Run 'nimble benchStress' for stress tests"

when isMainModule:
  main()