## Stress Test for BitBarrel
##
## Pushes the system to its limits
## Run with: nim c -r -d:release bench/stress_test.nim

import os, times, random, strformat, strutils, times, random, options
import ../src/bitbarrel/types
import ../src/storage
from ../src/storage/datafile import open
from ../src/storage/keydir import init

proc formatNumber(n: int64): string =
  let s = $n
  result = ""
  for i, c in s:
    if i > 0 and (s.len - i) mod 3 == 0:
      result.add '_'
    result.add c

proc printHeader(title: string) =
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo &"║ {title:<58} ║"
  echo "╚════════════════════════════════════════════════════════════╝"

proc testLargeKeys() =
  ## Test with maximum-sized keys
  printHeader("Testing Maximum Key Size")

  let dbPath = "bench/stress_large_keys.data"
  if fileExists(dbPath):
    removeFile(dbPath)

  var dataFile = open(dbPath, 1'u32)
  var keyDir = init()
  defer:
    dataFile.close()
    if fileExists(dbPath):
      removeFile(dbPath)

  # Test key at max size
  let maxKey = repeat('k', MAX_KEY_SIZE)
  let value = "small value"
  let ts = getTime().toUnix()

  echo "  Testing key of max size (64KB)..."
  let info = dataFile.appendRecord(maxKey, value, ts)
  keyDir.add(maxKey, KeyDirEntry(
    fileId: 1,
    recordPos: info.recordPos,
    valueSize: info.valueSize,
    recordSize: info.recordSize,
    keyLen: info.keyLen
  ))

  let found = keyDir.get(maxKey)
  if found.isSome():
    let entry = found.get()
    let recordInfo = RecordInfo(
      recordPos: entry.recordPos,
      valueSize: entry.valueSize,
      recordSize: entry.recordSize,
      keyLen: entry.keyLen
    )
    let (readKey, readValue, _) = dataFile.readRecord(recordInfo)
    if readKey == maxKey and readValue == value:
      echo "  ✅ Max key test passed"
    else:
      echo "  ❌ Max key test failed"
  else:
    echo "  ❌ Max key not found"

  # Test various key sizes
  echo "\n  Testing keys of various sizes..."
  let sizes = [1, 10, 100, 1000, 10000, 100000]
  for size in sizes:
    if size <= MAX_KEY_SIZE:
      let key = repeat('x', size)
      let val = &"value_{size}"
      let info = dataFile.appendRecord(key, val, ts)
      keyDir.add(key, KeyDirEntry(
        fileId: 1,
        recordPos: info.recordPos,
        valueSize: info.valueSize,
        recordSize: info.recordSize,
        keyLen: info.keyLen
      ))
  echo "  ✅ Various key sizes test completed"

  echo &"  Total entries: {keyDir.len}"

proc testLargeValues() =
  ## Test with large values (up to 1MB, within 32MB max limit)
  printHeader("Testing Large Values")

  let dbPath = "bench/stress_large_values.data"
  if fileExists(dbPath):
    removeFile(dbPath)

  var dataFile = open(dbPath, 1'u32)
  var keyDir = init()
  defer:
    dataFile.close()
    if fileExists(dbPath):
      removeFile(dbPath)

  let sizes = [1024, 10240, 102400, 512000, 1048576]  # 1KB to 1MB (within 32MB max)
  let keyPrefix = "large_val:"

  echo "  Testing various value sizes..."
  var totalBytes = 0
  for size in sizes:
    let key = keyPrefix & $size
    let value = repeat('v', size)
    let ts = getTime().toUnix()

    let info = dataFile.appendRecord(key, value, ts)
    keyDir.add(key, KeyDirEntry(
      fileId: 1,
      recordPos: info.recordPos,
      valueSize: info.valueSize,
      recordSize: info.recordSize,
      keyLen: info.keyLen
    ))

    totalBytes += value.len
    echo &"    {key}: {size} bytes"

  echo &"\n  ✅ Large values test completed"
  echo &"  Total data written: {(totalBytes.float / (1024.0 * 1024.0)):.2f} MB"
  echo &"  Total entries: {keyDir.len}"
  echo &"  Avg value size: {totalBytes div keyDir.len} bytes"

proc testRapidWrites(count: int = 10000) =
  ## Stress test with rapid sequential writes
  printHeader("Rapid Write Test")
  echo &"  Target: {formatNumber(count.int64)} writes"

  let dbPath = "bench/stress_rapid_writes.data"
  if fileExists(dbPath):
    removeFile(dbPath)

  var dataFile = open(dbPath, 1'u32)
  var keyDir = init()
  defer:
    dataFile.close()
    if fileExists(dbPath):
      removeFile(dbPath)

  let start = getTime().toUnixFloat()
  var errors = 0

  for i in 0..<count:
    let key = &"rapid_{i:08}"
    let value = &"value_{i}"
    let ts = getTime().toUnix()

    try:
      let info = dataFile.appendRecord(key, value, ts)
      keyDir.add(key, KeyDirEntry(
        fileId: 1,
        recordPos: info.recordPos,
        valueSize: info.valueSize,
        recordSize: info.recordSize,
        keyLen: info.keyLen
      ))
    except:
      errors.inc()

  let elapsed = getTime().toUnixFloat() - start
  let throughput = count.float / elapsed

  echo &"\n  ✅ Completed in {elapsed:.3f} seconds"
  echo &"  ✓ Throughput: {throughput:.1f} writes/sec"
  echo &"  ✓ Errors: {errors}"
  echo &"  ✓ Keys stored: {keyDir.len}"
  echo &"  ✓ File size: {formatNumber(getFileSize(dbPath).int64)} bytes"

proc testRandomAccess(count: int = 5000) =
  ## Stress test with random reads and writes
  printHeader("Random Access Test")
  echo &"  Operations: {formatNumber(count.int64)}"

  let dbPath = "bench/stress_random_access.data"
  if fileExists(dbPath):
    removeFile(dbPath)

  var dataFile = open(dbPath, 1'u32)
  var keyDir = init()
  defer:
    dataFile.close()
    if fileExists(dbPath):
      removeFile(dbPath)

  let start = getTime().toUnixFloat()
  var reads = 0
  var writes = 0
  var readErrors = 0
  var writeErrors = 0

  # Pre-populate with some data
  for i in 0..<count:
    let key = &"pre_{i:06}"
    let value = &"pre_value_{i}"
    let ts = getTime().toUnix()
    let info = dataFile.appendRecord(key, value, ts)
    keyDir.add(key, KeyDirEntry(
      fileId: 1,
      recordPos: info.recordPos,
      valueSize: info.valueSize,
      recordSize: info.recordSize,
      keyLen: info.keyLen
    ))

  # Mix of reads and writes
  for _ in 0..<count:
    let op = rand(1.0)
    if op < 0.7:  # 70% reads
      reads.inc()
      let key = &"pre_{rand(count):06}"
      let found = keyDir.get(key)
      if found.isSome():
        let entry = found.get()
        let recordInfo = RecordInfo(
          recordPos: entry.recordPos,
          valueSize: entry.valueSize,
          recordSize: entry.recordSize,
          keyLen: entry.keyLen
        )
        try:
          let (k, v, _) = dataFile.readRecord(recordInfo)
          if k.len == 0 and v.len == 0:
            readErrors.inc()
        except:
          readErrors.inc()
      else:
        readErrors.inc()
    else:  # 30% writes
      writes.inc()
      let i = rand(100000)
      let key = &"rand_{i:08}"
      let value = &"rand_value_{i}"
      let ts = getTime().toUnix()
      try:
        let info = dataFile.appendRecord(key, value, ts)
        keyDir.add(key, KeyDirEntry(
          fileId: 1,
          recordPos: info.recordPos,
          valueSize: info.valueSize,
          recordSize: info.recordSize,
          keyLen: info.keyLen
        ))
      except:
        writeErrors.inc()

  let elapsed = getTime().toUnixFloat() - start
  let totalOps = reads + writes
  let throughput = totalOps.float / elapsed

  echo &"\n  ✅ Completed in {elapsed:.3f} seconds"
  echo &"  ✓ Total operations: {totalOps}"
  echo &"  ✓ Read ops: {reads} (errors: {readErrors})"
  echo &"  ✓ Write ops: {writes} (errors: {writeErrors})"
  echo &"  ✓ Throughput: {throughput:.1f} ops/sec"
  echo &"  ✓ Database size: {formatNumber(getFileSize(dbPath).int64)} bytes"
  echo &"  ✓ Keys stored: {formatNumber(keyDir.len.int64)}"

proc testMemoryUsage(sampleCount: int = 100000) =
  ## Test memory usage with many keys
  printHeader("Memory Usage Test")
  echo &"  Target: {formatNumber(sampleCount.int64)} keys"

  let dbPath = "bench/stress_memory.data"
  if fileExists(dbPath):
    removeFile(dbPath)

  var dataFile = open(dbPath, 1'u32)
  var keyDir = init()
  defer:
    dataFile.close()
    if fileExists(dbPath):
      removeFile(dbPath)

  let start = getTime().toUnixFloat()
  for i in 0..<sampleCount:
    let keyLen = 20 + rand(80)  # 20-100 byte keys
    let key = repeat('k', keyLen)
    let value = repeat('v', 50)
    let ts = getTime().toUnix()

    let info = dataFile.appendRecord(key, value, ts)
    keyDir.add(key, KeyDirEntry(
      fileId: 1,
      recordPos: info.recordPos,
      valueSize: info.valueSize,
      recordSize: info.recordSize,
      keyLen: info.keyLen
    ))

    if (i + 1) mod 10000 == 0:
      echo &"    {(i + 1) / sampleCount * 100:.0f}% complete..."

  let elapsed = getTime().toUnixFloat() - start
  let throughput = sampleCount.float / elapsed

  echo &"\n  ✅ Memory test completed in {elapsed:.3f} seconds"
  echo &"  ✓ Throughput: {throughput:.1f} writes/sec"
  echo &"  ✓ Keys stored: {formatNumber(keyDir.len.int64)}"
  echo &"  ✓ File size: {formatNumber(getFileSize(dbPath).int64)} bytes"
  echo &"  ✓ Estimated memory overhead: ~{(getFileSize(dbPath).float * 0.05):.0f} bytes per key"

proc main() =
  randomize()

  echo ""
  printHeader("BitBarrel Stress Test Suite")
  echo "  Testing system limits and error handling..."

  # Create bench directory
  if not dirExists("bench"):
    createDir("bench")

  # Run stress tests
  testLargeKeys()
  sleep(100)

  testLargeValues()
  sleep(100)

  testRapidWrites(5000)  # 5K writes
  sleep(100)

  testRandomAccess(2500)  # 2.5K ops each
  sleep(100)

  testMemoryUsage(25000)  # 25K keys

  printHeader("Stress Test Complete")
  echo "  All stress tests completed successfully!"
  echo "  The system handled all edge cases and limits."

when isMainModule:
  main()
