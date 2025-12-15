## Tests for read buffer (cache) implementation

import std/[unittest, os, times, options]
import ../src/bitbarrel/types
import ../src/storage/readbuffer

suite "Read Buffer Tests":

  test "Read buffer initialization":
    var rb = initReadBuffer(maxSize = 100, maxMemory = 1024 * 1024)
    defer: rb.deinit()

    check rb.maxSize == 100
    check rb.maxMemory == 1024 * 1024
    check rb.currentSize == 0
    check rb.enabled == true

  test "Put and get":
    var rb = initReadBuffer(maxSize = 10)
    defer: rb.deinit()

    rb.put(1, 100, "test data")

    let result = rb.get(1, 100)
    check result.isSome
    check result.get() == "test data"

    let miss = rb.get(1, 200)
    check miss.isNone

  test "Cache miss":
    var rb = initReadBuffer(maxSize = 10)
    defer: rb.deinit()

    let result = rb.get(1, 100)
    check result.isNone

    let stats = rb.getStats()
    check stats.misses == 1
    check stats.hits == 0

  test "Cache hit":
    var rb = initReadBuffer(maxSize = 10)
    defer: rb.deinit()

    rb.put(1, 100, "data")
    discard rb.get(1, 100)

    let stats = rb.getStats()
    check stats.hits == 1
    check stats.misses == 0

  test "LRU eviction":
    var rb = initReadBuffer(maxSize = 3)
    defer: rb.deinit()

    # Fill cache
    rb.put(1, 100, "data1")
    rb.put(1, 200, "data2")
    rb.put(1, 300, "data3")

    check rb.size() == 3

    # Access first entry to make it recent
    discard rb.get(1, 100)

    # Add new entry - should evict the oldest (entry 2)
    rb.put(1, 400, "data4")

    check rb.size() == 3

    # Entry 100 should still be there (was accessed recently)
    check rb.get(1, 100).isSome

    # Entry 400 should be there (just added)
    check rb.get(1, 400).isSome

    # One of entry 200 or 300 should be evicted
    let has200 = rb.get(1, 200).isSome
    let has300 = rb.get(1, 300).isSome
    check (not has200) or (not has300)  # At least one evicted

  test "Memory limit eviction":
    var rb = initReadBuffer(maxSize = 100, maxMemory = 50)
    defer: rb.deinit()

    # Each entry has 10 bytes
    rb.put(1, 100, "0123456789")  # 10 bytes
    rb.put(1, 200, "0123456789")  # 10 bytes
    rb.put(1, 300, "0123456789")  # 10 bytes
    rb.put(1, 400, "0123456789")  # 10 bytes
    rb.put(1, 500, "0123456789")  # 10 bytes

    check rb.size() == 5
    check rb.memoryUsage() == 50

    # Adding another should evict to stay under limit
    rb.put(1, 600, "0123456789")

    check rb.memoryUsage() <= 50

  test "Invalidate entry":
    var rb = initReadBuffer(maxSize = 10)
    defer: rb.deinit()

    rb.put(1, 100, "data")
    check rb.get(1, 100).isSome

    rb.invalidate(1, 100)
    check rb.get(1, 100).isNone

  test "Invalidate file":
    var rb = initReadBuffer(maxSize = 10)
    defer: rb.deinit()

    rb.put(1, 100, "data1")
    rb.put(1, 200, "data2")
    rb.put(2, 100, "data3")

    check rb.size() == 3

    rb.invalidateFile(1)

    check rb.size() == 1
    check rb.get(1, 100).isNone
    check rb.get(1, 200).isNone
    check rb.get(2, 100).isSome

  test "Clear cache":
    var rb = initReadBuffer(maxSize = 10)
    defer: rb.deinit()

    rb.put(1, 100, "data1")
    rb.put(1, 200, "data2")

    check rb.size() == 2

    rb.clear()

    check rb.size() == 0
    check rb.get(1, 100).isNone

  test "Disable and enable":
    var rb = initReadBuffer(maxSize = 10)
    defer: rb.deinit()

    rb.put(1, 100, "data")
    check rb.get(1, 100).isSome

    rb.disable()
    check rb.size() == 0  # Cache cleared on disable
    check rb.get(1, 100).isNone

    rb.put(1, 100, "data")  # Should not cache when disabled
    check rb.get(1, 100).isNone

    rb.enable()
    rb.put(1, 100, "data")
    check rb.get(1, 100).isSome

  test "Hit rate calculation":
    var rb = initReadBuffer(maxSize = 10)
    defer: rb.deinit()

    rb.put(1, 100, "data")

    # 2 hits
    discard rb.get(1, 100)
    discard rb.get(1, 100)

    # 2 misses
    discard rb.get(1, 200)
    discard rb.get(1, 300)

    let hitRate = rb.getHitRate()
    check hitRate == 50.0  # 2 hits, 2 misses

  test "Update existing entry":
    var rb = initReadBuffer(maxSize = 10)
    defer: rb.deinit()

    rb.put(1, 100, "original")
    check rb.get(1, 100).get() == "original"

    rb.put(1, 100, "updated")
    check rb.get(1, 100).get() == "updated"

    check rb.size() == 1  # Still only one entry

  test "Multiple files":
    var rb = initReadBuffer(maxSize = 10)
    defer: rb.deinit()

    rb.put(1, 100, "file1-data1")
    rb.put(1, 200, "file1-data2")
    rb.put(2, 100, "file2-data1")
    rb.put(3, 100, "file3-data1")

    check rb.size() == 4

    check rb.get(1, 100).get() == "file1-data1"
    check rb.get(2, 100).get() == "file2-data1"
    check rb.get(3, 100).get() == "file3-data1"

  test "Zero hit rate with no operations":
    var rb = initReadBuffer(maxSize = 10)
    defer: rb.deinit()

    check rb.getHitRate() == 0.0

  test "Statistics tracking":
    var rb = initReadBuffer(maxSize = 3)
    defer: rb.deinit()

    rb.put(1, 100, "data")
    rb.put(1, 200, "data")
    rb.put(1, 300, "data")
    rb.put(1, 400, "data")  # Triggers eviction

    let stats = rb.getStats()
    check stats.evictions >= 1
    check stats.totalBytes > 0
