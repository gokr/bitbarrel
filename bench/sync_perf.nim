## Sync vs No-Sync Performance Comparison
##
## Demonstrates the dramatic impact of fsync on write performance

import os
import times
import strformat

import kvs/types
import storage/datafile
import storage/keydir

proc formatNumber(n: int64): string =
  ## Format large numbers with thousands separator
  $n

proc benchmark(label: string, dbPath: string, fsync: bool, count: int) =
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo &"║ {label:^58} ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo &"  Records: {formatNumber(count)}"
  echo &"  fsync: {fsync}"
  echo ""

  if fileExists(dbPath):
    removeFile(dbPath)

  let start = getTime().toUnixFloat()

  var dataFile = open(dbPath, 1'u32, syncImmediate, fsync, 0)
  var keyDir = init()
  defer:
    dataFile.close()

  for i in 0..<count:
    let key = &"key_{i:08}"
    let value = &"value_{i:08}"
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

  let elapsed = getTime().toUnixFloat() - start
  let throughput = count.float / elapsed

  echo &"  Time: {elapsed:.3f} seconds"
  echo &"  Throughput: {formatNumber(throughput.int64)} ops/sec"
  echo &"  File size: {formatNumber(getFileSize(dbPath).int64)} bytes"
  echo ""

proc main() =
  echo "⚡ KVS Sync Performance Impact Demonstration ⚡"
  echo ""

  let testSize = 50_000

  benchmark("With Fsync (Durable)", "bench/with_fsync.data", true, testSize)
  benchmark("Without Fsync (Fast)", "bench/without_fsync.data", false, testSize)

  echo ""
  echo ""
  echo "🎯 KEY INSIGHTS:"
  echo ""
  echo "  • fsync() forces data to disk on every write"
  echo "  • This ensures durability but kills performance"
  echo "  • Modern databases use write-ahead logs & group commit"
  echo "  • Consider periodic fsync for better performance"
  echo ""

when isMainModule:
  main()