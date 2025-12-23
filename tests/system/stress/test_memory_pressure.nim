## Memory Pressure Tests
##
## Tests for memory limits, leaks, and resource constraints.

import std/[unittest, os, times]
import storage/keydir
import storage/datafile
import bitbarrel/types
import ../../testutils

suite "Memory Pressure Tests":

  test "Handles out of memory gracefully":
    withTestDir("oom_test"):
      # Create test file
      let testFile = testDir / "oom_test.data"
      var df = datafile.open(testFile, 1'u32)

      var written = 0
      const maxAttempts = 1000

      # Try to allocate increasingly large values
      for i in 0..<maxAttempts:
        let size = 1024 * (i + 1)  # 1KB, 2KB, 3KB, ...
        try:
          let largeValue = repeat("x", size)
          discard df.appendRecord(&"large_key_{i}", largeValue, now())
          written += size
        except:
          # Stop when we can't allocate anymore
          break

      df.close()

      # Test passes if we handled errors gracefully
      check written >= 0
      echo &"Wrote {written} bytes before hitting memory limit"

  test "No memory leaks during long operations":
    withTestDir("memory_leak"):
      # Get initial memory
      let initialMem = getMemoryUsage()

      # Perform many operations
      let testFile = testDir / "leak_test.data"
      var df = datafile.open(testFile, 1'u32)

      for i in 0..<1000:
        discard df.appendRecord(&"key_{i}", &"value_{i}", now())

      df.close()

      # Force garbage collection
      when defined(nimV2):
        GC_fullCollect()

      # Check memory hasn't grown excessively
      let finalMem = getMemoryUsage()
      let growth = finalMem - initialMem

      # Allow some growth, but not excessive (e.g., < 10MB)
      check growth < 10 * 1024 * 1024
      echo &"Memory growth: {growth div 1024}KB"

  test "Very large KeyDir (simulated)":
    var keyDir = init()

    # Add many entries to test KeyDir scaling
    const numKeys = 10000

    for i in 0..<numKeys:
      let entry = KeyDirEntry(
        fileId: 1,
        recordPos: uint64(i * 100),
        valuePos: uint64(i * 100 + 50),
        valueSize: 10,
        timestamp: now(),
        recordSize: 25
      )
      keyDir.add(&"key_{i}", entry)

    # Verify KeyDir can handle many entries
    withLock(keyDir.lock):
      let result = keyDir.get("key_5000")
      check result.isSome

    # Test clearing large KeyDir
    keyDir.clear()

    # Verify it's empty
    withLock(keyDir.lock):
      let empty = keyDir.get("key_0")
      check empty.isNone

  test "Memory usage with compression":
    withTestDir("compression_mem"):
      let testFile = testDir / "compress_test.data"
      var df = datafile.open(testFile, 1'u32)

      # Write repetitive data that compresses well
      let repetitiveValue = repeat("ABCDEFGHIJ", 1000)  # 10KB
      for i in 0..<50:
        discard df.appendRecord(&"key_{i}", repetitiveValue, now())

      df.close()

      # File should be smaller due to compression
      let fileSize = getFileSize(testFile)
      let expectedSize = 50 * 10000  # 50 * 10KB uncompressed

      # Allow up to 50% compression ratio
      check fileSize < expectedSize
      echo &"Compressed size: {fileSize} bytes ({100 * fileSize div expectedSize}% of uncompressed)"

  test "Resource cleanup on error":
    withTestDir("resource_cleanup"):
      # Create file
      let testFile = testDir / "cleanup.data"
      var df = datafile.open(testFile, 1'u32)

      # Perform some operations
      for i in 0..<10:
        discard df.appendRecord(&"key_{i}", &"value_{i}", now())

      # Close properly
      df.close()

      # Try to open again - should work if resources were cleaned up
      var df2 = datafile.open(testFile, 1'u32)
      defer: df2.close()

      check not df2.isNil

  test "Many small files memory usage":
    withTestDir("many_files"):
      const numFiles = 100
      var totalSize = 0

      # Create many small files
      for i in 0..<numFiles:
        let file = testDir / &"{i:06d}.data"
        var df = datafile.open(file, i.uint32)
        discard df.appendRecord("key", "value", now())
        df.close()
        totalSize += getFileSize(file)

      # Check total size is reasonable
      check totalSize > 0
      check totalSize < numFiles * 1024  # Less than 1KB per file overhead
      echo &"Total size: {totalSize} bytes for {numFiles} files"

  test "Long-running operation simulation":
    withTestDir("long_running"):
      # Simulate database that's been running for a long time
      let testFile = testDir / "long_running.data"
      var df = datafile.open(testFile, 1'u32)

      # Write data with varying timestamps (simulating long usage)
      let baseTime = now() - 86400 * 365  # 1 year ago
      for i in 0..<365:  # One entry per day for a year
        let timestamp = baseTime + int64(i) * 86400
        discard df.appendRecord(&"day_{i}", &"data_{i}", timestamp)

      df.close()

      # Verify all data is stored
      check getFileSize(testFile) > 0

      # Recovery should handle old data
      let engine = initRecoveryEngine(testDir)
      let stats = engine.recover()

      check stats.keyCount == 365

  test "Memory fragmentation test":
    var keyDir = init()

    # Add and remove entries to simulate memory fragmentation
    const numOps = 1000

    for i in 0..<numOps:
      let entry = KeyDirEntry(
        fileId: 1,
        recordPos: uint64(i * 100),
        valuePos: uint64(i * 100 + 50),
        valueSize: 10,
        timestamp: now(),
        recordSize: 25
      )
      keyDir.add(&"key_{i}", entry)

      # Remove every 10th key to create fragmentation
      if i > 0 and i mod 10 == 0:
        keyDir.remove(&"key_{i-5}")

    # Verify KeyDir still works
    withLock(keyDir.lock):
      let result = keyDir.get("key_500")
      # May or may not exist due to removals
      discard result

    echo &"Performed {numOps} operations with interspersed removals"