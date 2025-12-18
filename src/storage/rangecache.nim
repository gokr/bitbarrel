## Range Cache - LRU cache for loaded range indexes
##
## Manages which range partitions are loaded in memory.
## Supports both hash-based (KeyDir) and CritBit-based indexes.
## Uses LRU eviction when cache is full.

import std/[tables, locks, options, os]
import ../bitbarrel/types
import keydir
import critbitindex
import rangehint
import critbithint

type
  # Generic range data that can hold either type
  RangeData* = object
    case accessModel*: AccessModel
    of amHash:
      keyDir*: KeyDir
    of amCritBit:
      critBit*: CritBitIndex

  RangeCache* = object
    accessModel*: AccessModel          # Fixed access model for this cache
    loadedRanges*: Table[RangeId, RangeData]   # Loaded range data
    lruList*: seq[RangeId]                       # Ordered by access time (oldest first)
    maxRanges*: int
    lock*: Lock
    numRanges*: int                # Total number of ranges
    dataDir*: string               # For hint file paths

proc init*(accessModel: AccessModel, maxRanges: int, numRanges: int, dataDir: string): RangeCache =
  ## Initialize a new range cache with specific access model
  result = RangeCache()
  result.accessModel = accessModel
  result.loadedRanges = initTable[RangeId, RangeData]()
  result.lruList = @[]
  result.maxRanges = maxRanges
  result.numRanges = numRanges
  result.dataDir = dataDir
  initLock(result.lock)

proc keyDirEntryToRangeHintEntries(keyDir: KeyDir): seq[RangeHintEntry] =
  ## Convert KeyDir to RangeHintEntry sequence for writing
  result = newSeq[RangeHintEntry]()
  for key, entry in keyDir.table.pairs:
    result.add(RangeHintEntry(
      key: key,
      recordPos: entry.recordPos,
      valuePos: entry.valuePos,
      valueSize: entry.valueSize,
      timestamp: entry.timestamp,
      recordSize: entry.recordSize,
      deleted: entry.deleted
    ))

proc getRangeDir(dataDir: string, accessModel: AccessModel): string =
  ## Get directory path for ranges based on access model
  let dirName = case accessModel
                of amHash: "hash"
                of amCritBit: "critbit"
  result = dataDir / "ranges" / dirName

proc getHintPath(cache: RangeCache, rangeId: RangeId): string =
  ## Get hint file path for a range
  let ext = case cache.accessModel
            of amHash: ".rhint"
            of amCritBit: ".chint"
  getRangeDir(cache.dataDir, cache.accessModel) / ("range_" & $rangeId & ext)

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
    # Move to end (most recently used)
    cache.lruList.delete(idx)
    cache.lruList.add(rangeId)
  else:
    # Add as most recently used
    cache.lruList.add(rangeId)

proc getRange*(cache: var RangeCache, rangeId: RangeId): Option[RangeData] =
  ## Get a loaded range data
  result = none(RangeData)
  withLock(cache.lock):
    if rangeId in cache.loadedRanges:
      result = some(cache.loadedRanges[rangeId])
      updateLRUInternal(cache, rangeId)

proc addRange*(cache: var RangeCache, rangeId: RangeId, data: RangeData) =
  ## Add a range index to cache
  withLock(cache.lock):
    # Remove existing if present
    if rangeId in cache.loadedRanges:
      cache.loadedRanges[rangeId] = data
    else:
      # Check if cache is full
      if cache.loadedRanges.len >= cache.maxRanges:
        let oldestId = cache.lruList[0]
        # Evict oldest range
        cache.loadedRanges.del(oldestId)
        cache.lruList.delete(0)

      # Add new range
      cache.loadedRanges[rangeId] = data
      updateLRUInternal(cache, rangeId)

proc removeRange*(cache: var RangeCache, rangeId: RangeId): bool =
  ## Remove a range from cache (saves to hint file)
  result = false
  withLock(cache.lock):
    if rangeId in cache.loadedRanges:
      let data = cache.loadedRanges[rangeId]
      let hintPath = cache.getHintPath(rangeId)

      # Save to hint file
      case cache.accessModel
      of amHash:
        let entries = keyDirEntryToRangeHintEntries(data.keyDir)
        if entries.len > 0:
          discard writeRangeHint(hintPath, rangeId, entries)
      of amCritBit:
        var tempIndex = data.critBit
        saveCritBitHint(tempIndex, rangeId, hintPath)

      result = true

proc flushAllRanges*(cache: var RangeCache): int =
  ## Flush all loaded ranges to their hint files
  result = 0
  withLock(cache.lock):
    for rangeId, data in cache.loadedRanges.pairs:
      let hintPath = cache.getHintPath(rangeId)

      case cache.accessModel
      of amHash:
        let entries = keyDirEntryToRangeHintEntries(data.keyDir)
        if entries.len > 0:
          discard writeRangeHint(hintPath, rangeId, entries)
      of amCritBit:
        var tempIndex = data.critBit
        saveCritBitHint(tempIndex, rangeId, hintPath)

      inc(result)

proc clear*(cache: var RangeCache) =
  ## Clear all ranges (saves to hint files)
  withLock(cache.lock):
    # Save all ranges first
    discard cache.flushAllRanges()

    # Clear data structures
    cache.loadedRanges.clear()
    cache.lruList.setLen(0)

proc evictAll*(cache: var RangeCache) =
  ## Evict all ranges from cache (saves to hint files first)
  cache.clear()

proc getStats*(cache: var RangeCache): tuple[loaded: int, max: int, total: int] =
  ## Get cache statistics
  withLock(cache.lock):
    result.loaded = cache.loadedRanges.len
    result.max = cache.maxRanges
    result.total = cache.numRanges

# Helper methods for accessing ranges with proper typing
proc getRangeKeyDir*(cache: var RangeCache, rangeId: RangeId): Option[KeyDir] =
  ## Get a range as KeyDir (only works for hash mode)
  if cache.accessModel != amHash:
    raise newException(ValueError, "Cache is not in hash mode")

  withLock(cache.lock):
    if rangeId in cache.loadedRanges:
      let rangeIdx = cache.loadedRanges[rangeId]
      if rangeIdx.accessModel == amHash:
        result = some(rangeIdx.keyDir)
        cache.updateLRUInternal(rangeId)

proc getRangeCritBit*(cache: var RangeCache, rangeId: RangeId): Option[CritBitIndex] =
  ## Get a range as CritBitIndex (only works for critbit mode)
  if cache.accessModel != amCritBit:
    raise newException(ValueError, "Cache is not in critbit mode")

  withLock(cache.lock):
    if rangeId in cache.loadedRanges:
      let rangeIdx = cache.loadedRanges[rangeId]
      if rangeIdx.accessModel == amCritBit:
        result = some(rangeIdx.critBit)
        cache.updateLRUInternal(rangeId)

proc getOrLoadRange*(cache: var RangeCache, rangeId: RangeId): Option[ptr KeyDir] =
  ## Get a range KeyDir, loading from hint file if necessary
  ## Only works for hash mode caches
  if cache.accessModel != amHash:
    return none(ptr KeyDir)

  withLock(cache.lock):
    # Check if already loaded
    if rangeId in cache.loadedRanges:
      cache.updateLRUInternal(rangeId)
      return some(addr cache.loadedRanges[rangeId].keyDir)

    # Need to load from hint file
    let hintPath = cache.getHintPath(rangeId)

    # Create new KeyDir for this range
    var newKeyDir = keydir.init()

    # Try to load from hint file (if exists)
    if fileExists(hintPath):
      discard loadKeyDirFromRangeHint(hintPath, newKeyDir)

    # Evict oldest if cache is full
    if cache.loadedRanges.len >= cache.maxRanges and cache.lruList.len > 0:
      let oldestId = cache.lruList[0]
      # Save evicted range to hint file before removing
      if oldestId in cache.loadedRanges:
        let oldData = cache.loadedRanges[oldestId]
        let oldHintPath = cache.getHintPath(oldestId)
        let entries = keyDirEntryToRangeHintEntries(oldData.keyDir)
        if entries.len > 0:
          discard writeRangeHint(oldHintPath, oldestId, entries)
      cache.loadedRanges.del(oldestId)
      cache.lruList.delete(0)

    # Add new range to cache
    let rangeData = RangeData(accessModel: amHash, keyDir: newKeyDir)
    cache.loadedRanges[rangeId] = rangeData
    cache.updateLRUInternal(rangeId)

    return some(addr cache.loadedRanges[rangeId].keyDir)

proc deinit*(cache: var RangeCache) =
  ## Cleanup resources
  deinitLock(cache.lock)