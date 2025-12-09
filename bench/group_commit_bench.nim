## Group Commit Performance Benchmark
##
## Demonstrates group commit as a middle ground between performance and durability

import os
import times
import strformat

import kvs/types
import storage/datafile_opt
import storage/keydir

proc formatNumber(n: int64): string =
  $n

proc benchmark(label: string, dbPath: string, procAppend: proc(k, v: string, ts: int64), count: int) =
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo &"║ {label:^58} ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo &"  Records: {formatNumber(count)}"
  echo ""

  if fileExists(dbPath):
    removeFile(dbPath)

  let start = getTime().toUnixFloat()

  for i in 0..<count:
    let key = &"key_{i:08}"
    let value = &"value_{i:08}"
    let ts = getTime().toUnix()
    procAppend(key, value, ts)

  let elapsed = getTime().toUnixFloat() - start
  let throughput = count.float / elapsed

  echo &"  Time: {elapsed:.3f} seconds"
  echo &"  Throughput: {formatNumber(throughput.int64)} ops/sec"
  echo &"  File size: {formatNumber(getFileSize(dbPath).int64)} bytes"
  echo ""

proc main() =
  echo "🚀 Group Commit Performance Analysis 🚀"
  echo ""

  let testSize = 100_000

  # Test 1: Traditional fsync every write
  echo "Test 1: Traditional - fsync every write"
  var df1 = open("bench/traditional.data", 1'u32, syncImmediate, true, 0)
  var kd1 = init()
  defer:
    df1.close()

  benchmark("Traditional (fsync every write)", "bench/traditional.data",
    proc(k, v: string, ts: int64) =
      let info = df1.appendRecordOpt(k, v, ts)
      kd1.add(k, KeyDirEntry(
        fileId: 1,
        recordPos: info.recordPos,
        valuePos: info.valuePos,
        valueSize: info.valueSize,
        timestamp: ts,
        recordSize: info.recordSize
      ))
    , testSize)

  # Test 2: Group commit - batch every 1000 writes
  echo "Test 2: Group Commit - batch every 1000 writes (100ms max)"
  var df2 = openWithGroupCommit("bench/groupcommit.data", 1'u32, 1000, 100)
  var kd2 = init()
  defer:
    df2.close()

  benchmark("Group Commit (batch 1000, 100ms)", "bench/groupcommit.data",
    proc(k, v: string, ts: int64) =
      let info = df2.appendRecordOpt(k, v, ts)
      kd2.add(k, KeyDirEntry(
        fileId: 1,
        recordPos: info.recordPos,
        valuePos: info.valuePos,
        valueSize: info.valueSize,
        timestamp: ts,
        recordSize: info.recordSize
      ))
    , testSize)

  # Test 3: Group commit - force sync on every 10th write (simulating critical data)
  echo "Test 3: Group Commit - force sync every 10th write"
  var df3 = openWithGroupCommit("bench/mixed.data", 1'u32, 500, 50)
  var kd3 = init()
  defer:
    df3.close()

  var counter = 0
  benchmark("Mixed (force sync every 10th)", "bench/mixed.data",
    proc(k, v: string, ts: int64) =
      inc counter
      let force = (counter mod 10 == 0)
      let info = df3.appendRecordOpt(k, v, ts, forceSync = force)
      kd3.add(k, KeyDirEntry(
        fileId: 1,
        recordPos: info.recordPos,
        valuePos: info.valuePos,
        valueSize: info.valueSize,
        timestamp: ts,
        recordSize: info.recordSize
      ))
    , testSize)

  echo ""
  echo "💡 Takeaways:"
  echo "  • Group commit provides massive performance improvement"
  echo "  • Can be tuned based on durability requirements"
  echo "  • Force sync for critical operations"
  echo "  • Default: sync every 1000 writes or 100ms"
  echo ""

when isMainModule:
  main()