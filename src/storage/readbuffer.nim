## Read Buffer Implementation for Read-Ahead Caching
##
## This module provides an in-memory cache for read operations to reduce
## disk I/O and improve read throughput through caching frequently accessed data.

import std/[tables, times, locks, options, algorithm]
import ../kvs/types

type
  CacheKey* = tuple[fileId: uint32, offset: uint64]

  CacheEntry* = object
    data*: string           # Cached record data
    accessTime*: Time       # Last access time for LRU eviction
    accessCount*: int       # Access count for statistics

  ReadBufferStats* = object
    hits*: int64            # Cache hits
    misses*: int64          # Cache misses
    evictions*: int64       # Entries evicted
    totalBytes*: int64      # Total bytes stored

  ReadBuffer* = object
    cache*: Table[CacheKey, CacheEntry]
    maxSize*: int           # Maximum number of entries
    maxMemory*: int64       # Maximum memory in bytes (0 = unlimited)
    currentSize*: int       # Current number of entries
    currentMemory*: int64   # Current memory usage
    stats*: ReadBufferStats
    lock*: Lock
    enabled*: bool          # Whether caching is enabled

proc initReadBuffer*(maxSize: int = 1000, maxMemory: int64 = 0): ReadBuffer =
  ## Initialize a new read buffer
  ## maxSize: Maximum number of entries to cache
  ## maxMemory: Maximum memory in bytes (0 = unlimited based on entry count)

  result = ReadBuffer(
    cache: initTable[CacheKey, CacheEntry](),
    maxSize: maxSize,
    maxMemory: maxMemory,
    currentSize: 0,
    currentMemory: 0,
    stats: ReadBufferStats(),
    enabled: true
  )
  initLock(result.lock)

proc deinit*(rb: var ReadBuffer) =
  ## Clean up resources
  deinitLock(rb.lock)
  rb.cache.clear()
  rb.currentSize = 0
  rb.currentMemory = 0

proc evictOldest*(rb: var ReadBuffer): bool =
  ## Evict the least recently used entry
  ## Returns true if an entry was evicted

  if rb.currentSize == 0:
    return false

  # Find oldest entry
  var oldestKey: CacheKey
  var oldestTime = getTime()
  var found = false

  for key, entry in rb.cache.pairs:
    if not found or entry.accessTime < oldestTime:
      oldestKey = key
      oldestTime = entry.accessTime
      found = true

  if found:
    let entry = rb.cache[oldestKey]
    rb.currentMemory -= entry.data.len.int64
    rb.cache.del(oldestKey)
    dec rb.currentSize
    inc rb.stats.evictions
    return true

  return false

proc evictUntilSpace*(rb: var ReadBuffer, neededBytes: int64): bool =
  ## Evict entries until there's enough space for neededBytes
  ## Returns true if space was made available

  if rb.maxMemory == 0:
    # Memory limit not set, just check entry count
    while rb.currentSize >= rb.maxSize:
      if not rb.evictOldest():
        return false
    return true

  # Evict until we have enough memory
  while rb.currentMemory + neededBytes > rb.maxMemory or rb.currentSize >= rb.maxSize:
    if not rb.evictOldest():
      return false

  return true

proc get*(rb: var ReadBuffer, fileId: uint32, offset: uint64): Option[string] =
  ## Get cached data for the given file and offset
  ## Returns None if not in cache

  if not rb.enabled:
    return none(string)

  let key: CacheKey = (fileId, offset)

  withLock(rb.lock):
    if key in rb.cache:
      # Update access time
      rb.cache[key].accessTime = getTime()
      inc rb.cache[key].accessCount
      inc rb.stats.hits
      return some(rb.cache[key].data)
    else:
      inc rb.stats.misses
      return none(string)

proc put*(rb: var ReadBuffer, fileId: uint32, offset: uint64, data: string) =
  ## Store data in the cache

  if not rb.enabled:
    return

  let key: CacheKey = (fileId, offset)
  let dataSize = data.len.int64

  withLock(rb.lock):
    # Check if already in cache
    if key in rb.cache:
      # Update existing entry
      let oldSize = rb.cache[key].data.len.int64
      rb.currentMemory -= oldSize
      rb.cache[key] = CacheEntry(
        data: data,
        accessTime: getTime(),
        accessCount: rb.cache[key].accessCount + 1
      )
      rb.currentMemory += dataSize
      rb.stats.totalBytes += (dataSize - oldSize)
      return

    # Make space if needed
    if not rb.evictUntilSpace(dataSize):
      # Can't make space, don't cache
      return

    # Add new entry
    rb.cache[key] = CacheEntry(
      data: data,
      accessTime: getTime(),
      accessCount: 1
    )
    inc rb.currentSize
    rb.currentMemory += dataSize
    rb.stats.totalBytes += dataSize

proc invalidate*(rb: var ReadBuffer, fileId: uint32, offset: uint64) =
  ## Remove a specific entry from the cache

  let key: CacheKey = (fileId, offset)

  withLock(rb.lock):
    if key in rb.cache:
      let entry = rb.cache[key]
      rb.currentMemory -= entry.data.len.int64
      rb.cache.del(key)
      dec rb.currentSize

proc invalidateFile*(rb: var ReadBuffer, fileId: uint32) =
  ## Remove all entries for a specific file

  withLock(rb.lock):
    var keysToRemove: seq[CacheKey] = @[]

    for key in rb.cache.keys:
      if key.fileId == fileId:
        keysToRemove.add(key)

    for key in keysToRemove:
      let entry = rb.cache[key]
      rb.currentMemory -= entry.data.len.int64
      rb.cache.del(key)
      dec rb.currentSize

proc clear*(rb: var ReadBuffer) =
  ## Clear all cached data

  withLock(rb.lock):
    rb.cache.clear()
    rb.currentSize = 0
    rb.currentMemory = 0

proc enable*(rb: var ReadBuffer) =
  ## Enable caching
  rb.enabled = true

proc disable*(rb: var ReadBuffer) =
  ## Disable caching (clears cache)
  rb.enabled = false
  rb.clear()

proc getStats*(rb: var ReadBuffer): ReadBufferStats =
  ## Get cache statistics (thread-safe)
  withLock(rb.lock):
    result = rb.stats

proc getHitRate*(rb: var ReadBuffer): float =
  ## Get cache hit rate as a percentage
  withLock(rb.lock):
    let total = rb.stats.hits + rb.stats.misses
    if total == 0:
      return 0.0
    return rb.stats.hits.float / total.float * 100.0

proc size*(rb: var ReadBuffer): int =
  ## Get current number of cached entries
  withLock(rb.lock):
    result = rb.currentSize

proc memoryUsage*(rb: var ReadBuffer): int64 =
  ## Get current memory usage in bytes
  withLock(rb.lock):
    result = rb.currentMemory
