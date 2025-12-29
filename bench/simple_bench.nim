## Simple Benchmark for BitBarrel
##
## Run with: nim c -d:release bench/simple_bench.nim
## Or with nimble: nimble bench

import os
import times
import strformat
import strutils
import random
import options
import ../src/bitbarrel/types
import ../src/storage
from ../src/storage/datafile import open
from ../src/storage/keydir import init

proc formatNumber(n: int64): string =
  ## Format large numbers with commas
  result = $n
  var i = result.len - 3
  while i > 0:
    result.insert("_", i)
    i.dec(3)

proc printHeader(title: string) =
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo &"║ {title:<58} ║"
  echo "╚════════════════════════════════════════════════════════════╝"

proc benchmarkWrites(dataFile: var DataFile, keyDir: var KeyDir, count: int) =
  ## Benchmark write operations
  printHeader("Write Benchmark")
  echo &"  Records to write: {formatNumber(count.int64)}"

  let start = getTime().toUnixFloat()
  var valueSizeTotal = 0

  for i in 0..<count:
    let key = &"key_{i:08}"
    let value = &"value_{i:08}_" & repeat('x', 50)  # ~60 byte values
    let ts = getTime().toUnix()

    let info = dataFile.appendRecord(key, value, ts)
    keyDir.add(key, KeyDirEntry(
      fileId: 1,
      recordPos: info.recordPos,
      valueSize: info.valueSize,
      recordSize: info.recordSize,
      keyLen: info.keyLen
    ))

    valueSizeTotal += value.len

  let elapsed = getTime().toUnixFloat() - start
  let throughput = count.float / elapsed
  let mibWritten = (valueSizeTotal.float + (count * 60).float) / (1024.0 * 1024.0)  # Approximate total size

  echo &"  ✓ Completed in {elapsed:.3f} seconds"
  echo &"  ✓ Throughput: {throughput:.0f} ops/sec"
  echo &"  ✓ Data rate: {mibWritten / elapsed:.2f} MiB/sec"
  echo &"  ✓ Avg latency: {(elapsed * 1000.0 / count.float):.3f} ms per op"

proc benchmarkReads(dataFile: var DataFile, keyDir: var KeyDir, count: int, random: bool = false) =
  ## Benchmark read operations
  let accessType = if random: "Random" else: "Sequential"
  printHeader(&"Read Benchmark ({accessType})")
  echo &"  Records to read: {formatNumber(count.int64)}"

  if random:
    randomize()

  let start = getTime().toUnixFloat()
  var foundCount = 0

  for i in 0..<count:
    let keyIdx = if random: rand(count - 1) else: i
    let key = &"key_{keyIdx:08}"

    let found = keyDir.get(key)
    if found.isSome():
      let entry = found.get()
      let recordInfo = RecordInfo(
        recordPos: entry.recordPos,
        valueSize: entry.valueSize,
        recordSize: entry.recordSize,
        keyLen: entry.keyLen
      )
      let (_, readValue, _) = dataFile.readRecord(recordInfo)
      if readValue.len > 0:
        foundCount.inc()

  let elapsed = getTime().toUnixFloat() - start
  let throughput = count.float / elapsed
  let hitRate = foundCount.float / count.float * 100.0

  echo &"  ✓ Completed in {elapsed:.3f} seconds"
  echo &"  ✓ Throughput: {throughput:.0f} ops/sec"
  echo &"  ✓ Hit rate: {hitRate:.1f}%"
  echo &"  ✓ Avg latency: {(elapsed * 1000.0 / count.float):.3f} ms per op"

proc benchmarkMixed(dataFile: var DataFile, keyDir: var KeyDir, count: int, readRatio: float = 0.8) =
  ## Benchmark mixed workload (reads and writes)
  printHeader("Mixed Workload Benchmark")
  echo &"  Total operations: {formatNumber(count.int64)}"
  echo &"  Read ratio: {readRatio * 100:.1f}%"
  echo &"  Write ratio: {(1.0 - readRatio) * 100:.1f}%"

  let start = getTime().toUnixFloat()
  var reads = 0
  var writes = 0

  for i in 0..<count:
    if rand(1.0) < readRatio:
      # Read
      reads.inc()
      let key = &"key_{rand(i + 1):08}"
      let found = keyDir.get(key)
      if found.isSome():
        let entry = found.get()
        let recordInfo = RecordInfo(
          recordPos: entry.recordPos,
          valueSize: entry.valueSize,
          recordSize: entry.recordSize,
          keyLen: entry.keyLen
        )
        discard dataFile.readRecord(recordInfo)
    else:
      # Write
      writes.inc()
      let key = &"key_mixed_{i:08}"
      let value = &"value_{i:08}"
      let ts = getTime().toUnix()

      let info = dataFile.appendRecord(key, value, ts)
      keyDir.add(key, KeyDirEntry(
        fileId: 1,
        recordPos: info.recordPos,
        valueSize: info.valueSize,
        recordSize: info.recordSize,
        keyLen: info.keyLen
      ))

  let elapsed = getTime().toUnixFloat() - start
  let throughput = count.float / elapsed
  let readThroughput = reads.float / elapsed
  let writeThroughput = writes.float / elapsed

  echo &"  ✓ Completed in {elapsed:.3f} seconds"
  echo &"  ✓ Overall throughput: {throughput:.0f} ops/sec"
  echo &"  ✓ Read throughput: {readThroughput:.0f} ops/sec ({reads} ops)"
  echo &"  ✓ Write throughput: {writeThroughput:.0f} ops/sec ({writes} ops)"

proc printSystemInfo() =
  ## Print system information
  printHeader("System Information")
  echo &"  Nim version: {NimVersion}"
  echo &"  Build: {CompileDate} {CompileTime}"
  echo &"  OS: {hostOS}"
  echo &"  CPU: {hostCPU}"
  echo "  Optimization: ", if defined(release): "Release" else: "Debug"
when defined(gcDestructors):
  echo &"  GC: ARC/ORC"
else:
  echo &"  GC: Boehm"

echo ""

proc main() =
  randomize()

  printSystemInfo()

  let dbPath = "bench/benchmark.data"
  let testSize = 10_000  # Number of records

  # Clean up any existing file
  if fileExists(dbPath):
    removeFile(dbPath)

  # Create benchmark directory if needed
  let (dir, _) = splitPath(dbPath)
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)

  # Open database
  echo ""
  printHeader("Opening Database")
  var dataFile = open(dbPath, 1'u32)
  var keyDir = init()
  defer:
    dataFile.close()
    if fileExists(dbPath):
      removeFile(dbPath)

  # Run benchmarks
  benchmarkWrites(dataFile, keyDir, testSize)

  echo ""
  echo "Waiting 1 second for I/O to settle..."
  sleep(1000)

  benchmarkReads(dataFile, keyDir, testSize, random = false)

  echo ""
  echo "Waiting 1 second for I/O to settle..."
  sleep(1000)

  benchmarkReads(dataFile, keyDir, testSize, random = true)

  echo ""
  echo "Waiting 1 second for I/O to settle..."
  sleep(1000)

  benchmarkMixed(dataFile, keyDir, testSize, readRatio = 0.8)

  # Final statistics
  echo ""
  printHeader("Final Database Statistics")
  echo &"  Total keys: {formatNumber(keyDir.len.int64)}"
  echo &"  Database file size: {formatNumber(getFileSize(dbPath).int64)} bytes"
  let header = dataFile.readHeader()
  echo &"  Records written: {testSize}"
  echo &"  Avg record size: {(getFileSize(dbPath).float - header.fileSize.float) / testSize.float:.1f} bytes"

  # Clean up handled by defer

when isMainModule:
  main()
