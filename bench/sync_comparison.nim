## Multi-Mode Sync Comparison Benchmark
##
## Run with: nim c -d:release bench/sync_comparison.nim
## This benchmark compares different sync modes:
## - Immediate fsync: Full durability (~647 ops/sec)
## - Buffered: No fsync (~10K-50K ops/sec)
## - Write buffer: Batched writes (~5K-10K ops/sec)

import os
import times
import strformat
import strutils
from ../src/kvs/types import FileHeader, HEADER_SIZE
from ../src/storage/datafile import open
from ../src/storage.keydir import init
from ../src/storage.writebuffer import SyncMode

proc formatNumber(n: int64): string =
  ## Format large numbers with commas
  result = $n
  var i = result.len - 3
  while i > 0:
    result.insert("_", i)
    i.dec(3)

proc benchmarkSyncMode(modeName: string, syncMode: SyncMode, shouldFsync: bool, bufferSize: int = 0, numRecords = 1000) =
  ## Benchmark a specific sync configuration
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo &"  {modeName}"
  echo "════════════════════════════════════════════════════════════"
  echo &"  Sync mode: {syncMode}"
  echo &"  fsync: {shouldFsync}"
  echo &"  Buffer size: {bufferSize} bytes"
  echo ""

  let dbPath = &"bench/sync_test_{modeName.replace(" ", "_").toLowerAscii()}.data"

  # Clean up any existing file
  if fileExists(dbPath):
    removeFile(dbPath)

  # Open database with specific sync mode
  let startOpen = getTime().toUnixFloat()
  var dataFile = if bufferSize > 0:
    open(dbPath, 1'u32, syncMode, shouldFsync, bufferSize)
  else:
    open(dbPath, 1'u32, syncMode, shouldFsync, 0)
  var keyDir = init()

  let openTime = (getTime().toUnixFloat() - startOpen) * 1000.0
  echo &"  Database opened in {openTime:.1f} ms"
  echo ""

  # Write benchmark
  echo "  Write Benchmark:"
  let startWrite = getTime().toUnixFloat()

  for i in 0..<numRecords:
    let key = &"key_{i:06}"
    let value = &"value_{i:06}_test_data_xyz"
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

  let writeElapsed = getTime().toUnixFloat() - startWrite
  let writeThroughput = numRecords.float / writeElapsed

  echo &"    Records:      {formatNumber(numRecords.int64)}"
  echo &"    Time:         {writeElapsed:.3f} sec"
  echo &"    Throughput:   {writeThroughput:.0f} ops/sec"
  echo &"    Latency:      {(writeElapsed * 1000.0 / numRecords.float):.3f} ms per op"
  echo &"    File size:    {formatNumber(getFileSize(dbPath).int64)} bytes"
  echo ""

  # Read benchmark
  echo "  Read Benchmark:"
  sleep(100)  # Let I/O settle

  let startRead = getTime().toUnixFloat()
  var foundCount = 0

  for i in 0..<numRecords:
    let key = &"key_{i:06}"
    let found = keyDir.get(key)

    if found.isSome():
      let entry = found.get()
      let recordInfo = RecordInfo(
        recordPos: entry.recordPos,
        valuePos: entry.valuePos,
        valueSize: entry.valueSize,
        recordSize: entry.recordSize
      )
      let (_, value, _) = dataFile.readRecord(recordInfo)
      if value.len > 0:
        foundCount.inc()

  let readElapsed = getTime().toUnixFloat() - startRead
  let readThroughput = numRecords.float / readElapsed

  echo &"    Records:      {formatNumber(numRecords.int64)}"
  echo &"    Time:         {readElapsed:.3f} sec"
  echo &"    Throughput:   {readThroughput:.0f} ops/sec"
  echo &"    Latency:      {(readElapsed * 1000.0 / numRecords.float):.3f} ms per op"
  echo &"    Found:        {foundCount}/{numRecords} ({foundCount.float / numRecords.float * 100:.1f}%)"
  echo ""

  # Close database
  dataFile.close()

  # Clean up
  if fileExists(dbPath):
    removeFile(dbPath)

proc printHeader(title: string) =
  echo ""
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo &"║  {title:<62}  ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""

when isMainModule:
  echo ""
  printHeader("KVS Sync Mode Comparison Benchmark")
  echo &"  Nim: {NimVersion}, Build: {CompileDate}, Mode: {when defined(release): "Release" else: "Debug"}"
  echo ""

  # Test different configurations
  # Each config will write/read 1000 records

  echo "═════════════════════════════════════════════════════════════════"
  echo "  DURABILITY COMPARISON: What you get for the performance trade-off"
  echo "═════════════════════════════════════════════════════════════════"
  echo ""

  benchmarkSyncMode(
    modeName = "Immediate fsync (safest)",
    syncMode = syncImmediate,
    shouldFsync = true,
    bufferSize = 0,
    numRecords = 1000
  )

  echo "  💾 Guarantees: Data survives power loss, kernel panic, abrupt shutdown"
  echo ""

  benchmarkSyncMode(
    modeName = "Periodic + fsync (buffered)",
    syncMode = syncPeriodic,
    shouldFsync = true,
    bufferSize = 8192,
    numRecords = 1000
  )

  echo "  💾 Guarantees: Data survives power loss (within 100ms window)"
  echo "  ⚠️  Risk: Up to 100ms of writes can be lost on crash"
  echo ""

  benchmarkSyncMode(
    modeName = "Periodic + no fsync (fastest)",
    syncMode = syncPeriodic,
    shouldFsync = false,
    bufferSize = 8192,
    numRecords = 1000
  )

  echo "  💾 Guarantees: NONE - data lost on crash or power failure"
  echo "      Use case: Cache, temporary data, non-critical logs"
  echo ""

  printHeader("Benchmark Complete")
  echo ""
