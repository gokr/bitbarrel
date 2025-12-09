## Performance vs Durability Trade-off Demonstration
##
## Shows different sync strategies and their impact

import os
import times
import strformat

import kvs/types
import storage/datafile
import storage/keydir
from storage.record import Record, encode, crc32
when defined(posix):
  import posix

proc formatNumber(n: int64): string =
  $n

proc benchmarkSyncModes(count: int = 10000) =
  echo ""
  echo "🔄 SYNC STRATEGY COMPARISON 🔄"
  echo ""
  echo &"Operations: {formatNumber(count)} writes per test"
  echo ""

  # Test 1: Full durability (fsync every write)
  echo "1️⃣  Full Durability (fsync every write)"
  echo "   - Maximum durability, minimum performance"
  echo "   - Safe from crashes, but very slow"

  if fileExists("bench/full_durable.data"):
    removeFile("bench/full_durable.data")

  let start1 = getTime().toUnixFloat()
  var df1 = open("bench/full_durable.data", 1'u32)
  var kd1 = init()

  for i in 0..<count:
    let key = &"key_{i:08}"
    let value = &"val_{i:08}"
    let ts = getTime().toUnix()

    let info = df1.appendRecord(key, value, ts)
    kd1.add(key, KeyDirEntry(
      fileId: 1,
      recordPos: info.recordPos,
      valuePos: info.valuePos,
      valueSize: info.valueSize,
      timestamp: ts,
      recordSize: info.recordSize
    ))

  df1.close()
  let time1 = getTime().toUnixFloat() - start1

  echo &"   ✓ Time: {time1:.3f}s"
  echo &"   ✓ Throughput: {formatNumber((count.float / time1).int64)} ops/sec"
  echo ""

  # Test 2: No fsync (maximum performance, zero durability)
  echo "2️⃣  Performance Mode (no fsync)"
  echo "   - Maximum performance, zero durability"
  echo "   - Data loss likely on crash"
  echo "   ⚠️  NOT FOR PRODUCTION"

  if fileExists("bench/performance.data"):
    removeFile("bench/performance.data")

  # Direct file API to bypass fsync
  let file = open("bench/performance.data", fmReadWrite)
  if getFileSize("bench/performance.data") == 0:
    var header = FileHeader(
      magic: ['B', 'C', 'K', 'S'],
      version: VERSION,
      created: getTime().toUnix(),
      fileSize: HEADER_SIZE.uint64
    )
    discard file.writeBuffer(addr header, HEADER_SIZE)
    file.flushFile()
    file.setFilePos(0, fspEnd)

  let start2 = getTime().toUnixFloat()
  var pos2 = getFileSize("bench/performance.data").uint64
  var kd2 = init()

  for i in 0..<count:
    let record = Record(key: &"key_{i:08}", value: &"val_{i:08}", timestamp: getTime().toUnix())
    let encoded = record.encode()
    let crc = crc32(encoded)

    # Write directly without fsync
    discard file.writeBuffer(addr crc, 4)
    discard file.writeBuffer(encoded.cstring, encoded.len)
    pos2 += (4 + encoded.len).uint64

    # Add to KeyDir
    let recordPos = pos2 - (4 + encoded.len).uint64 + 4 + 8 + 4 + record.key.len.uint64
    kd2.add(record.key, KeyDirEntry(
      fileId: 1,
      recordPos: recordPos,
      valuePos: recordPos,
      valueSize: record.value.len.uint32,
      timestamp: record.timestamp,
      recordSize: (4 + encoded.len).uint32
    ))

  file.flushFile()  # Only once at the end
  file.close()
  let time2 = getTime().toUnixFloat() - start2

  echo &"   ✓ Time: {time2:.3f}s"
  echo &"   ✓ Throughput: {formatNumber((count.float / time2).int64)} ops/sec"
  echo ""

  # Test 3: Periodic sync (compromise)
  echo "3️⃣  Periodic Sync (compromise)"
  echo "   - Sync every N writes"
  echo "   - Middle ground for performance/durability"

  if fileExists("bench/periodic.data"):
    removeFile("bench/periodic.data")

  let file3 = open("bench/periodic.data", fmReadWrite)
  if getFileSize("bench/periodic.data") == 0:
    var header = FileHeader(
      magic: ['B', 'C', 'K', 'S'],
      version: VERSION,
      created: getTime().toUnix(),
      fileSize: HEADER_SIZE.uint64
    )
    discard file3.writeBuffer(addr header, HEADER_SIZE)
    file3.flushFile()
    when defined(posix):
      discard fsync(file3.getFileHandle())
    file3.setFilePos(0, fspEnd)

  let start3 = getTime().toUnixFloat()
  var pos3 = getFileSize("bench/periodic.data").uint64
  var kd3 = init()
  const SYNC_INTERVAL = 1000  # Sync every 1000 writes

  for i in 0..<count:
    let record = Record(key: &"key_{i:08}", value: &"val_{i:08}", timestamp: getTime().toUnix())
    let encoded = record.encode()
    let crc = crc32(encoded)

    discard file3.writeBuffer(addr crc, 4)
    discard file3.writeBuffer(encoded.cstring, encoded.len)
    pos3 += (4 + encoded.len).uint64

    if (i + 1) mod SYNC_INTERVAL == 0:
      file3.flushFile()
      when defined(posix):
        discard fsync(file3.getFileHandle())

    # Add to KeyDir
    let recordPos = pos3 - (4 + encoded.len).uint64 + 4 + 8 + 4 + record.key.len.uint64
    kd3.add(record.key, KeyDirEntry(
      fileId: 1,
      recordPos: recordPos,
      valuePos: recordPos,
      valueSize: record.value.len.uint32,
      timestamp: record.timestamp,
      recordSize: (4 + encoded.len).uint32
    ))

  file3.close()
  let time3 = getTime().toUnixFloat() - start3

  echo &"   ✓ Time: {time3:.3f}s"
  echo &"   ✓ Throughput: {formatNumber((count.float / time3).int64)} ops/sec"
  echo ""

  # Summary
  echo "📊 SUMMARY TABLE"
  echo ""
  echo "Strategy               Throughput     Time      Worst-case data loss"
  echo "────────────────────────────────────────────────────────────────"
  echo &"Full Durability        {formatNumber((count.float / time1).int64):>10} ops/sec  {time1:>6.2f}s  0 operations"
  echo &"Periodic (1K)           {formatNumber((count.float / time3).int64):>10} ops/sec  {time3:>6.2f}s  ~999 operations"
  echo &"Performance (No sync)   {formatNumber((count.float / time2).int64):>10} ops/sec  {time2:>6.2f}s  All in memory"
  echo ""

  let speedupNoSync = (count.float / time2) / (count.float / time1)
  let speedupPeriodic = (count.float / time3) / (count.float / time1)

  echo "📈 PERFORMANCE IMPROVEMENTS"
  echo ""
  echo &"• No fsync is {speedupNoSync:.1f}x faster than full durability"
  echo &"• Periodic sync is {speedupPeriodic:.1f}x faster than full durability"
  echo &"• Periodic sync risks only {SYNC_INTERVAL-1} operations on crash"
  echo ""

proc main() =
  benchmarkSyncModes(10000)

  echo "💡 RECOMMENDATIONS"
  echo ""
  echo "For Production Use:"
  echo "• Use full fsync for critical financial data"
  echo "• Use periodic sync for most applications"
  echo "• Tune sync interval based on your tolerance for data loss"
  echo "• Consider background checkpointing for recovery"
  echo ""
  echo "Common Configurations:"
  echo "• Financial systems: fsync every write or every 100 ops"
  echo "• Web applications: fsync every 1000-10000 ops"
  echo "• Analytics/Logging: fsync every second or every MB"
  echo ""

when isMainModule:
  main()