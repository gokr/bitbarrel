## High-Performance KVS Benchmark
##
## This benchmark disables fsync to test maximum throughput
## WARNING: Do not use in production - data may be lost on crash

import os
import times
import random
import strformat
import stats

import kvs/types
import storage/datafile
import storage/keydir

proc formatNumber(n: int64): string =
  ## Format large numbers with thousands separator
  var s = $n
  var result = ""
  for i, c in s:
    result.add(c)
    if (s.len - i - 1) mod 3 == 0 and i != s.len - 1:
      result.add(',')
  result

proc printHeader(title: string) =
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo &"║ {title:^58} ║"
  echo "╚════════════════════════════════════════════════════════════╝"

proc benchmarkWritesNoFsync(dataFile: var DataFile, keyDir: var KeyDir, count: int) =
  ## Benchmark write operations without fsync
  printHeader("High-Performance Write Benchmark (NO FSYNC)")
  echo &"  Records to write: {formatNumber(count.int64)}"
  echo ""
  echo "  ⚠️  WARNING: fsync disabled - data may be lost on crash!"
  echo ""

  let start = getTime().toUnixFloat()
  var totalSize = 0

  for i in 0..<count:
    let key = &"perf_key_{i:08}"
    let value = &"perf_value_{i:08}_with_some_additional_data_to_increase_size"
    let ts = getTime().toUnix()

    let info = dataFile.appendRecord(key, value, ts)
    keyDir.add(key, KeyDirEntry(
      fileId: 1,
      recordPos: info.recordPos,
      valuePos: info.valuePos,
      valueSize: info.valueSize,
      timestamp: ts,
      recordSize: info.recordSize
    ))

    totalSize += info.recordSize.int64

  let elapsed = getTime().toUnixFloat() - start
  let throughput = count.float / elapsed
  let dataRate = (totalSize.float / (1024 * 1024)) / elapsed
  let latency = (elapsed * 1000) / count.float

  echo ""
  echo &"  ✓ Completed in {elapsed:.3f} seconds"
  echo &"  ✓ Throughput: {formatNumber(throughput.int64)} ops/sec"
  echo &"  ✓ Data rate: {dataRate:.2f} MiB/sec"
  echo &"  ✓ Avg latency: {latency:.3f} ms per op"
  echo ""

proc benchmarkBufferedWrites(dataFile: var DataFile, keyDir: var KeyDir, count: int) =
  ## Benchmark write operations with write buffering
  printHeader("Buffered Write Benchmark (WITH FSYNC)")
  echo &"  Records to write: {formatNumber(count.int64)}"
  echo ""

  let start = getTime().toUnixFloat()
  var totalSize = 0

  for i in 0..<count:
    let key = &"buf_key_{i:08}"
    let value = &"buf_value_{i:08}_with_some_additional_data_to_increase_size"
    let ts = getTime().toUnix()

    let info = dataFile.appendRecord(key, value, ts)
    keyDir.add(key, KeyDirEntry(
      fileId: 1,
      recordPos: info.recordPos,
      valuePos: info.valuePos,
      valueSize: info.valueSize,
      timestamp: ts,
      recordSize: info.recordSize
    ))

    totalSize += info.recordSize.int64

  let elapsed = getTime().toUnixFloat() - start
  let throughput = count.float / elapsed
  let dataRate = (totalSize.float / (1024 * 1024)) / elapsed
  let latency = (elapsed * 1000) / count.float

  echo ""
  echo &"  ✓ Completed in {elapsed:.3f} seconds"
  echo &"  ✓ Throughput: {formatNumber(throughput.int64)} ops/sec"
  echo &"  ✓ Data rate: {dataRate:.2f} MiB/sec"
  echo &"  ✓ Avg latency: {latency:.3f} ms per op"
  echo ""

proc main() =
  randomize()

  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║          KVS High-Performance Benchmark                  ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""

  let dbPath1 = "bench/perf_nofsync.data"
  let dbPath2 = "bench/perf_buffered.data"
  let testSize = 100_000  # 100k records for better measurement

  # Clean up any existing files
  for path in [dbPath1, dbPath2]:
    if fileExists(path):
      removeFile(path)

  # Create benchmark directory if needed
  let (dir, _) = splitPath(dbPath1)
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)

  # Test 1: No fsync for maximum throughput
  printHeader("Test 1: Direct Writes without Fsync")
  var dataFile1 = open(dbPath1, 1'u32, syncImmediate, false, 0)  # No fsync!
  var keyDir1 = init()
  defer:
    dataFile1.close()

  benchmarkWritesNoFsync(dataFile1, keyDir1, testSize)

  echo &"  Database file size: {formatNumber(getFileSize(dbPath1).int64)} bytes"
  echo ""

  # Test 2: Buffered writes with periodic sync
  printHeader("Test 2: Buffered Writes (64KB buffer)")
  var dataFile2 = open(dbPath2, 1'u32, syncBuffered, true, 64 * 1024)  # 64KB buffer
  var keyDir2 = init()
  defer:
    dataFile2.close()

  benchmarkBufferedWrites(dataFile2, keyDir2, testSize)

  echo &"  Database file size: {formatNumber(getFileSize(dbPath2).int64)} bytes"
  echo ""

when isMainModule:
  main()