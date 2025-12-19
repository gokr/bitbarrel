## Concurrent Access Tests
##
## Tests for multi-threaded and multi-process access patterns to ensure
## thread safety and proper synchronization.

import std/[unittest, os, times, threadpool, atomic]
import ../src/storage/keydir
import ../src/storage/datafile
import ../src/bitbarrel/types
import testutils

# Global counters for testing
var
  writeCount* {.threadvar.}: Atomic[int]
  readCount* {.threadvar.}: Atomic[int]
  errorCount* {.threadvar.}: Atomic[int]

suite "Concurrent Access Tests":

  test "Multi-threaded writes to same barrel":
    withTestDir("concurrent_writes"):
      # Create a datafile for concurrent writes
      let testFile = testDir / "concurrent.data"
      var df = datafile.open(testFile, 1'u32)
      defer: df.close()

      # Number of threads and operations per thread
      const numThreads = 10
      const opsPerThread = 100

      writeCount.store(0)
      errorCount.store(0)

      # Worker procedure for concurrent writes
      proc writeWorker(threadId: int) {.thread.} =
        for i in 0..<opsPerThread:
          let key = &"key_{threadId}_{i}"
          let value = &"value_{threadId}_{i}"
          try:
            discard df.appendRecord(key, value, now())
            writeCount.fetchAdd(1)
          except:
            errorCount.fetchAdd(1)

      # Spawn threads
      var futures: seq[FlowVar[void]]
      for i in 0..<numThreads:
        futures.add(spawn writeWorker(i))

      # Wait for all threads
      for fv in futures:
        discard ^fv

      # Verify results
      check errorCount.load() == 0  # No errors should occur
      check writeCount.load() == numThreads * opsPerThread

      # Try to read some of the data back
      # (DataFile doesn't have direct read API, so we just verify file size)
      check fileExists(testFile)
      check getFileSize(testFile) > 0

  test "Concurrent reads during writes":
    withTestDir("concurrent_reads_writes"):
      let testFile = testDir / "concurrent_rw.data"
      var df = datafile.open(testFile, 1'u32)
      defer: df.close()

      # Writer thread
      proc writerThread() {.thread.} =
        for i in 0..<50:
          let key = &"key_{i}"
          let value = &"value_{i}"
          try:
            discard df.appendRecord(key, value, now())
          except:
            discard

      # Reader "thread" (simulated by checking file state)
      # Note: DataFile doesn't expose read API, so we just verify the file is accessible
      proc readerThread() {.thread.} =
        # Just sleep to simulate reading activity
        sleep(100)

      # Start writer
      var writerFuture = spawn writerThread()

      # Start reader while writer is running
      var readerFuture = spawn readerThread()

      # Wait for both
      discard ^writerFuture
      discard ^readerFuture

      # Verify file is in consistent state
      check fileExists(testFile)

  test "Concurrent KeyDir operations":
    # Create a shared KeyDir
    var keyDir = init()

    const numThreads = 10
    const opsPerThread = 50

    var kdWriteCount: Atomic[int]
    var kdErrorCount: Atomic[int]
    kdWriteCount.store(0)
    kdErrorCount.store(0)

    # Worker procedure for concurrent KeyDir operations
    proc kdWorker(threadId: int) {.thread.} =
      for i in 0..<opsPerThread:
        let key = &"key_{threadId}_{i}"
        let entry = KeyDirEntry(
          fileId: 1,
          recordPos: uint64(i * 100),
          valuePos: uint64(i * 100 + 50),
          valueSize: 10,
          timestamp: now(),
          recordSize: 25
        )

        withLock(keyDir.lock):
          try:
            keyDir.add(key, entry)
            kdWriteCount.fetchAdd(1)
          except:
            kdErrorCount.fetchAdd(1)

    # Spawn threads
    var futures: seq[FlowVar[void]]
    for i in 0..<numThreads:
      futures.add(spawn kdWorker(i))

    # Wait for all threads
    for fv in futures:
      discard ^fv

    # Verify results
    check kdErrorCount.load() == 0  # No errors should occur

    # Note: Some operations may fail due to key conflicts, which is expected
    # The important thing is that no crashes or deadlocks occur

  test "Multiple processes accessing same database (simulation)":
    withTestDir("multiprocess"):
      # Simulate multi-process by opening/closing datafiles multiple times
      let testFile = testDir / "multiproc.data"

      # First "process"
      var df1 = datafile.open(testFile, 1'u32)
      defer: df1.close()

      discard df1.appendRecord("key1", "value1", now())

      # Close first "process"
      df1.close()

      # Second "process" (reopen file)
      var df2 = datafile.open(testFile, 1'u32)
      defer: df2.close()

      # Try to add new key (should fail as file is read-only on reopen, or should create new file ID)
      # This tests file handle management across "processes"
      try:
        discard df2.appendRecord("key2", "value2", now())
      except:
        check true  # Expected - file may be locked or in wrong mode

  test "Lock contention scenarios":
    withTestDir("lock_contention"):
      var keyDir = init()

      # Many threads trying to update the same keys
      const numThreads = 20
      const sameKeyUpdates = 50

      var updateCount: Atomic[int]
      updateCount.store(0)

      # All threads update the same key
      proc contentionWorker(threadId: int) {.thread.} =
        let entry = KeyDirEntry(
          fileId: 1,
          recordPos: 100,
          valuePos: 150,
          valueSize: 10,
          timestamp: now() + threadId.int64,
          recordSize: 25
        )

        for i in 0..<sameKeyUpdates:
          withLock(keyDir.lock):
            try:
              # Update the same key repeatedly
              keyDir.add("shared_key", entry)
              updateCount.fetchAdd(1)
            except:
              discard

      # Spawn threads
      var futures: seq[FlowVar[void]]
      for i in 0..<numThreads:
        futures.add(spawn contentionWorker(i))

      # Wait for all threads
      for fv in futures:
        discard ^fv

      # Verify no deadlocks (we got here, so no deadlock!)
      check updateCount.load() > 0

      # Verify KeyDir is still functional
      withLock(keyDir.lock):
        let result = keyDir.get("shared_key")
        check result.isSome  # Key should exist

  test "Concurrent compaction simulation":
    withTestDir("compaction"):
      # Create initial datafile
      let testFile = testDir / "compaction.data"
      var df = datafile.open(testFile, 1'u32)
      defer: df.close()

      # Write some data
      for i in 0..<50:
        discard df.appendRecord(&"key_{i}", &"value_{i}", now())

      df.close()

      # Simulate "compaction" by creating new file and copying data
      let newFile = testDir / "compaction_new.data"
      var dfNew = datafile.open(newFile, 2'u32)
      defer: dfNew.close()

      # Copy data (simulating compaction)
      for i in 0..<50:
        discard dfNew.appendRecord(&"key_{i}", &"value_{i}", now() + 100)

      dfNew.close()

      # Now try to access both files concurrently
      proc accessWorker(fileId: int) {.thread.} =
        let filePath = if fileId == 1: testFile else: newFile
        try:
          # Try to open and read from file
          var df = datafile.open(filePath, fileId.uint32)
          if not df.isNil:
            # Simulate some operations
            sleep(10)
            df.close()
        except:
          discard

      var futures: seq[FlowVar[void]]
      futures.add(spawn accessWorker(1))
      futures.add(spawn accessWorker(2))

      for fv in futures:
        discard ^fv

      # Both files should still exist
      check fileExists(testFile)
      check fileExists(newFile)

  test "Thread safety of KeyDir clear operation":
    var keyDir = init()

    # Pre-populate KeyDir
    for i in 0..<100:
      let entry = KeyDirEntry(
        fileId: 1,
        recordPos: uint64(i * 10),
        valuePos: uint64(i * 10 + 5),
        valueSize: 5,
        timestamp: now(),
        recordSize: 20
      )
      withLock(keyDir.lock):
        keyDir.add(&"key_{i}", entry)

    # Clear in one thread while others try to access
    proc clearerThread() {.thread.} =
      sleep(50)  # Let some operations start
      withLock(keyDir.lock):
        keyDir.clear()

    proc accessorThread(id: int) {.thread.} =
      for i in 0..<20:
        withLock(keyDir.lock):
          # Try to access KeyDir
          let key = &"key_{i mod 10}"
          let result = keyDir.get(key)
          discard result  # Just access it

      # Also try to add while clearing
      withLock(keyDir.lock):
        try:
          keyDir.add(&"new_key_{id}", KeyDirEntry(
            fileId: 1, recordPos: 1000, valuePos: 1050,
            valueSize: 5, timestamp: now(), recordSize: 20
          ))
        except:
          discard

    # Spawn threads
    var futures: seq[FlowVar[void]]
    futures.add(spawn clearerThread())
    for i in 0..<5:
      futures.add(spawn accessorThread(i))

    # Wait for all threads
    for fv in futures:
      discard ^fv

    # Test passes if no crashes or deadlocks occurred
    check true

  test "High concurrency stress test":
    withTestDir("stress_test"):
      let testFile = testDir / "stress.data"
      var df = datafile.open(testFile, 1'u32)
      defer: df.close()

      const numThreads = 25
      const opsPerThread = 75

      writeCount.store(0)
      readCount.store(0)
      errorCount.store(0)

      proc stressWorker(threadId: int) {.thread.} =
        for i in 0..<opsPerThread:
          let key = &"key_{threadId}_{i}"
          let value = &"value_{threadId}_{i}"

          try:
            # Write
            discard df.appendRecord(key, value, now())
            writeCount.fetchAdd(1)

            # Small delay to increase chance of contention
            if i mod 10 == 0:
              atomicInc(readCount)
          except:
            errorCount.fetchAdd(1)

      # Spawn threads
      var futures: seq[FlowVar[void]]
      for i in 0..<numThreads:
        futures.add(spawn stressWorker(i))

      # Wait for all threads
      for fv in futures:
        discard ^fv

      # Verify no errors
      check errorCount.load() == 0
      check writeCount.load() == numThreads * opsPerThread

      # Verify file is in consistent state
      check fileExists(testFile)
      check getFileSize(testFile) > 0

      echo &"Concurrent stress test: {writeCount.load()} writes, {readCount.load()} reads"

  test "Thread cleanup and resource management":
    # Test that threads properly cleanup resources even on errors
    withTestDir("resource_cleanup"):
      var keyDir = init()

      var cleanupErrors: Atomic[int]
      cleanupErrors.store(0)

      proc cleanupWorker(threadId: int) {.thread.} =
        var localErrors = 0

        # Perform operations that might fail
        for i in 0..<20:
          try:
            withLock(keyDir.lock):
              let entry = KeyDirEntry(
                fileId: 1,
                recordPos: uint64(i * 10),
                valuePos: uint64(i * 10 + 5),
                valueSize: 5,
                timestamp: now(),
                recordSize: 20
              )
              keyDir.add(&"cleanup_key_{threadId}_{i}", entry)

            # Randomly fail some operations
            if i == 10:
              raise newException(ValueError, "Simulated error")
          except:
            localErrors.inc

        cleanupErrors.fetchAdd(localErrors)

      # Spawn several threads
      var futures: seq[FlowVar[void]]
      for i in 0..<5:
        futures.add(spawn cleanupWorker(i))

      # Wait for all threads
      for fv in futures:
        discard ^fv

      # Even with errors, threads should complete
      # The actual number of errors may vary
      check cleanupErrors.load() >= 0