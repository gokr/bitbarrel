## Range Cache - LRU cache for loaded range KeyDirs
##
## Manages which range partitions are loaded in memory.
## Uses LRU eviction when cache is full.

import std/[tables, locks, options, os]
import ../bitbarrel/types
import keydir
import rangehint

type
  RangeCache* = object
    loadedRanges*: Table[RangeId, KeyDir]
    lruList*: seq[RangeId]           # Ordered by access time (oldest first)
    maxRanges*: int
    lock*: Lock
    numRanges*: int                  # Total number of ranges
    dataDir*: string                 # For hint file paths

proc init*(maxRanges: int, numRanges: int, dataDir: string): RangeCache =
  ## Initialize a new range cache
  result = RangeCache()
  result.loadedRanges = initTable[RangeId, KeyDir]()
  result.lruList = @[]
  result.maxRanges = maxRanges
  result.numRanges = numRanges
  result.dataDir = dataDir
  initLock(result.lock)

proc getHintPath(cache: RangeCache, rangeId: RangeId): string =
  ## Get hint file path for a range
  cache.dataDir / "ranges" / ("range_" & $rangeId & ".rhint")

proc isLoaded*(cache: var RangeCache, rangeId: RangeId): bool =
  ## Check if a range is currently loaded
  withLock(cache.lock):
    result = rangeId in cache.loadedRanges

proc loadedCount*(cache: var RangeCache): int =
  ## Get number of currently loaded ranges
  withLock(cache.lock):
    result = cache.loadedRanges.len

# Internal: update LRU without lock (must be called with lock held)
proc updateLRUInternal(cache: var RangeCache, rangeId: RangeId) =
  var idx = -1
  for i, id in cache.lruList:
    if id == rangeId:
      idx = i
      break
  if idx >= 0:
    cache.lruList.delete(idx)
  cache.lruList.add(rangeId)

# Internal: evict oldest range without lock (must be called with lock held)
proc evictLRUInternal(cache: var RangeCache): Option[RangeId] =
  if cache.lruList.len == 0:
    return none(RangeId)

  let rangeId = cache.lruList[0]
  cache.lruList.delete(0)

  # Flush to hint file before evicting if we have data
  if rangeId in cache.loadedRanges:
    var kd = cache.loadedRanges[rangeId]
    let hintPath = cache.getHintPath(rangeId)
    discard saveKeyDirToRangeHint(hintPath, rangeId, kd)
    kd.deinit()
    cache.loadedRanges.del(rangeId)

  return some(rangeId)

proc getOrLoadRange*(cache: var RangeCache, rangeId: RangeId): Option[ptr KeyDir] =
  ## Get a range from cache, loading from disk if needed
  ## Returns pointer to KeyDir, or none on failure

  withLock(cache.lock):
    # Already loaded?
    if rangeId in cache.loadedRanges:
      cache.updateLRUInternal(rangeId)
      return some(addr cache.loadedRanges[rangeId])

    # Need to evict if cache is full
    while cache.loadedRanges.len >= cache.maxRanges:
      let evicted = cache.evictLRUInternal()
      if evicted.isNone():
        break

    # Create new KeyDir and load from hint
    var kd = keydir.init()
    let hintPath = cache.getHintPath(rangeId)

    if rangeHintExists(hintPath):
      let loaded = loadKeyDirFromRangeHint(hintPath, kd)
      if loaded < 0:
        kd.deinit()
        return none(ptr KeyDir)

    # Add to cache
    cache.loadedRanges[rangeId] = kd
    cache.lruList.add(rangeId)

    return some(addr cache.loadedRanges[rangeId])

proc flushRange*(cache: var RangeCache, rangeId: RangeId): bool =
  ## Flush a range to its hint file
  ## Returns true if successful

  withLock(cache.lock):
    if rangeId notin cache.loadedRanges:
      return true  # Nothing to flush

    var kd = cache.loadedRanges[rangeId]
    let hintPath = cache.getHintPath(rangeId)
    return saveKeyDirToRangeHint(hintPath, rangeId, kd)

proc flushAllRanges*(cache: var RangeCache): int =
  ## Flush all loaded ranges to their hint files
  ## Returns number of ranges flushed

  withLock(cache.lock):
    var flushed = 0
    for rangeId in cache.loadedRanges.keys:
      var kd = cache.loadedRanges[rangeId]
      let hintPath = cache.getHintPath(rangeId)
      if saveKeyDirToRangeHint(hintPath, rangeId, kd):
        inc flushed
    return flushed

proc evictAll*(cache: var RangeCache) =
  ## Evict all ranges (flush first)

  withLock(cache.lock):
    # Flush and cleanup all
    for rangeId in cache.loadedRanges.keys:
      var kd = cache.loadedRanges[rangeId]
      let hintPath = cache.getHintPath(rangeId)
      discard saveKeyDirToRangeHint(hintPath, rangeId, kd)
      kd.deinit()

    cache.loadedRanges.clear()
    cache.lruList = @[]

proc deinit*(cache: var RangeCache) =
  ## Cleanup resources
  cache.evictAll()
  deinitLock(cache.lock)

proc stats*(cache: var RangeCache): tuple[loaded: int, maxRanges: int] =
  ## Get cache statistics
  withLock(cache.lock):
    result = (loaded: cache.loadedRanges.len, maxRanges: cache.maxRanges)
