## HugeBarrel - Two-tier storage for massive datasets
##
## Coordinates between Barrel1 (CritBit for RangeKeyDirs) and Barrel2 (data files)

import std/[tables, options, os, strformat, algorithm, locks, times]
import ../bitbarrel/types
import ../bitbarrel/barrel
import ../storage/datafile
import rangekeydir

const
  DEFAULT_RANGE_CACHE_SIZE = 10
  DEFAULT_MAX_ENTRIES_PER_RANGE = 100_000
  DEFAULT_MAX_DATA_FILE_SIZE_MB = 1024

type
  RangeKeyDirCache* = object
    cache*: Table[string, RangeKeyDir]  # rangeKey -> RangeKeyDir
    lruList*: seq[string]               # LRU order (oldest first)
    maxSize*: int
    lock*: Lock

  HugeBarrel* = ref object
    path*: string
    config*: HugeBarrelConfig

    # Barrel1: CritBit barrel storing RangeKeyDirs
    barrel1*: Barrel

    # Barrel2: Multiple data files
    barrel2Files*: Table[uint32, DataFile]
    nextFileId*: uint32
    currentFile*: DataFile
    currentFileId*: uint32
    currentFileSize*: uint64

    # Range metadata in memory
    ranges*: seq[tuple[minKey: string, maxKey: string, rangeKey: string]]
    rangeKeyCache*: RangeKeyDirCache

proc initRangeKeyDirCache(maxSize: int): RangeKeyDirCache =
  ## Initialize LRU cache for RangeKeyDirs
  result.cache = initTable[string, RangeKeyDir]()
  result.lruList = @[]
  result.maxSize = maxSize
  initLock(result.lock)

proc evictLRU(cache: var RangeKeyDirCache) =
  ## Evict least recently used RangeKeyDir
  if cache.lruList.len == 0:
    return

  let oldestKey = cache.lruList[0]
  cache.lruList.delete(0)
  cache.cache.del(oldestKey)

proc cacheGet(cache: var RangeKeyDirCache, rangeKey: string): Option[RangeKeyDir] =
  ## Get RangeKeyDir from cache, update LRU
  withLock(cache.lock):
    if rangeKey in cache.cache:
      # Move to end (most recent)
      let index = cache.lruList.find(rangeKey)
      if index >= 0:
        cache.lruList.delete(index)
        cache.lruList.add(rangeKey)
      return some(cache.cache[rangeKey])
    else:
      return none(RangeKeyDir)

proc cachePut(cache: var RangeKeyDirCache, rangeKey: string, rkd: RangeKeyDir) =
  ## Put RangeKeyDir in cache
  withLock(cache.lock):
    # Evict if at capacity
    if cache.lruList.len >= cache.maxSize:
      cache.evictLRU()

    # Add to cache and LRU list
    cache.cache[rangeKey] = rkd
    cache.lruList.add(rangeKey)

proc cacheClear*(cache: var RangeKeyDirCache) =
  ## Clear the cache
  withLock(cache.lock):
    cache.cache.clear()
    cache.lruList = @[]

# --- Range finding ---

proc findRangeForKey*(hb: HugeBarrel, key: string): string =
  ## Find which range a key belongs to
  ## Returns rangeKey or empty string if not found

  # For now, with single range, return the first range
  if hb.ranges.len == 0:
    return ""

  # With range splitting not yet implemented, just return the first range
  # This will be updated in Phase 4
  return hb.ranges[0].rangeKey

proc addRangeMetadata(hb: var HugeBarrel, rangeKey: string, minKey: string, maxKey: string) =
  ## Add range metadata to in-memory list
  hb.ranges.add((minKey: minKey, maxKey: maxKey, rangeKey: rangeKey))
  hb.ranges.sort(proc(a, b: auto): int = cmp(a.minKey, b.minKey))

# --- Data file management ---

proc getOrCreateDataFile(hb: var HugeBarrel, fileId: uint32): DataFile =
  ## Get a Barrel2 file by ID, create if needed
  if fileId in hb.barrel2Files:
    return hb.barrel2Files[fileId]

  # Create file
  let filePath = hb.path / "barrel2" / fmt"file_{fileId:06d}.data"
  createDir(hb.path / "barrel2")

  var dataFile = open(filePath, fileId, syncImmediate, false, 64*1024, false)

  hb.barrel2Files[fileId] = dataFile
  return dataFile

proc createNewDataFile(hb: var HugeBarrel) =
  ## Create a new data file when current is full
  hb.currentFileId = hb.nextFileId
  inc(hb.nextFileId)

  let filePath = hb.path / "barrel2" / fmt"file_{hb.currentFileId:06d}.data"
  createDir(hb.path / "barrel2")

  hb.currentFile = open(filePath, hb.currentFileId, syncImmediate, false, 64*1024, false)
  hb.currentFileSize = 0

# --- RangeKeyDir operations ---

proc loadRangeKeyDir(hb: var HugeBarrel, rangeKey: string): RangeKeyDir =
  ## Load a RangeKeyDir from Barrel1

  # Check cache first
  let cached = hb.rangeKeyCache.cacheGet(rangeKey)
  if cached.isSome():
    return cached.get()

  # Load from Barrel1
  let serialized = hb.barrel1.get(rangeKey)
  if serialized == "":
    # Create empty RangeKeyDir
    return newRangeKeyDir()

  let rkd = deserialize(serialized)
  hb.rangeKeyCache.cachePut(rangeKey, rkd)
  return rkd

proc loadRangeKeyDir(hb: HugeBarrel, rangeKey: string): RangeKeyDir =
  ## Load a RangeKeyDir from Barrel1 (const version)
  var mutableHb = hb
  result = loadRangeKeyDir(mutableHb, rangeKey)

proc saveRangeKeyDir(hb: var HugeBarrel, rangeKey: string, rkd: var RangeKeyDir) =
  ## Save a RangeKeyDir to Barrel1
  let serialized = rkd.serialize()
  discard hb.barrel1.set(rangeKey, serialized)

  # Update cache
  hb.rangeKeyCache.cachePut(rangeKey, rkd)

  # Update range metadata
  var found = false
  for i in 0..<hb.ranges.len:
    if hb.ranges[i].rangeKey == rangeKey:
      hb.ranges[i] = (minKey: rkd.minKey, maxKey: rkd.maxKey, rangeKey: rangeKey)
      found = true
      break

  if not found:
    hb.ranges.add((minKey: rkd.minKey, maxKey: rkd.maxKey, rangeKey: rangeKey))
    hb.ranges.sort(proc(a, b: auto): int = cmp(a.minKey, b.minKey))

# --- Key operations ---

proc get*(hb: var HugeBarrel, key: string): string =
  ## Get value for a key

  # Find which range this key belongs to
  let rangeKey = hb.findRangeForKey(key)
  if rangeKey == "":
    return ""

  # Load the RangeKeyDir
  let rkd = hb.loadRangeKeyDir(rangeKey)

  # Find the entry
  let entry = rkd.find(key)
  if entry.isNone() or entry.get().deleted:
    return ""

  # Read from data file
  let fileId = entry.get().fileId
  var dataFile = hb.getOrCreateDataFile(fileId)

  # Build RecordInfo
  var recordInfo: RecordInfo
  recordInfo.recordPos = entry.get().recordPos
  recordInfo.valuePos = entry.get().valuePos
  recordInfo.valueSize = entry.get().valueSize
  recordInfo.recordSize = entry.get().recordSize

  let (key, value, timestamp) = dataFile.readRecord(recordInfo)
  return value

proc get*(hb: HugeBarrel, key: string): string =
  ## Get value for a key (const version)
  var mutableHb = hb
  result = get(mutableHb, key)

proc set*(hb: var HugeBarrel, key: string, value: string, ttl: int = -1): bool =
  ## Set a key-value pair

  if hb.barrel1.isClosed():
    return false

  # Find or create range for this key
  var rangeKey = hb.findRangeForKey(key)
  if rangeKey == "":
    # Create new range
    rangeKey = fmt"R{hb.nextFileId:010d}"
    hb.ranges.add((minKey: key, maxKey: key, rangeKey: rangeKey))
    hb.ranges.sort(proc(a, b: auto): int = cmp(a.minKey, b.minKey))

  # Load RangeKeyDir
  var rkd = hb.loadRangeKeyDir(rangeKey)

  # Create new file if current is too large
  let maxSize = hb.config.maxDataFileSizeMB.uint64 * 1024 * 1024
  if hb.currentFileSize > maxSize:
    hb.createNewDataFile()

  # Write to data file
  let rawTimestamp = getTime().toUnix() * 1000
  let ttlToUse = if ttl == -1: 0 else: ttl

  var currentFile = hb.currentFile
  let recordInfo = currentFile.appendRecord(
    key = key,
    value = value,
    timestamp = rawTimestamp
    # TODO: TTL support (Phase 6)
  )

  # Update RangeKeyDir
  let entry = RangeKeyDirEntry(
    key: key,
    fileId: hb.currentFileId,
    recordPos: recordInfo.recordPos,
    valuePos: recordInfo.valuePos,
    valueSize: recordInfo.valueSize,
    timestamp: rawTimestamp,
    recordSize: recordInfo.recordSize,
    deleted: false
  )

  rkd.insert(key, entry)
  rkd.isDirty = true

  # Save RangeKeyDir if buffer is full
  if rkd.shouldFlush():
    rkd.flush()
    hb.saveRangeKeyDir(rangeKey, rkd)

  # Check if range needs splitting
  if rkd.len() > hb.config.maxEntriesPerRange:
    # TODO: Implement range splitting (Phase 4)
    echo fmt"Range {rangeKey} has {rkd.len()} entries, exceeds max {hb.config.maxEntriesPerRange}"

  hb.currentFileSize += recordInfo.recordSize + 4  # +4 for CRC
  return true

proc delete*(hb: var HugeBarrel, key: string): bool =
  ## Delete a key (tombstone)

  let rangeKey = hb.findRangeForKey(key)
  if rangeKey == "":
    return false

  var rkd = hb.loadRangeKeyDir(rangeKey)

  let existing = rkd.find(key)
  if existing.isNone():
    return false

  # Mark as deleted
  var entry = existing.get()
  entry.deleted = true
  rkd.insert(key, entry)

  # Save immediately
  rkd.flush()
  hb.saveRangeKeyDir(rangeKey, rkd)

  return true

proc exists*(hb: HugeBarrel, key: string): bool =
  ## Check if key exists
  let value = hb.get(key)
  return value.len > 0

# --- Initialization ---

proc openHugeBarrel*(path: string, config: BarrelConfig): HugeBarrel =
  ## Open a HugeBarrel

  # Validate config
  if config.mode != bmHugeCritBit:
    raise newException(ValueError, "Config mode must be bmHugeCritBit")

  result = HugeBarrel(
    path: path,
    config: config.hugeConfig,
    barrel2Files: initTable[uint32, DataFile](),
    nextFileId: 1,
    currentFileId: 0,
    currentFileSize: 0,
    ranges: @[]
  )

  # Ensure directories exist
  createDir(path / "barrel1")
  createDir(path / "barrel2")

  # Open Barrel1 (CritBit mode)
  var barrel1Config = config
  barrel1Config.mode = bmCritBit
  barrel1Config.autoCompact = false  # We'll handle compaction separately

  result.barrel1 = openBarrel(path / "barrel1" / "000001.data", 1, barrel1Config)

  # Initialize cache
  let cacheSize = if config.hugeConfig.rangeCacheSize > 0: config.hugeConfig.rangeCacheSize
                  else: DEFAULT_RANGE_CACHE_SIZE
  result.rangeKeyCache = initRangeKeyDirCache(cacheSize)

  # If this is a new barrel, create initial range
  if result.barrel1.count() == 0:
    let initialRangeKey = "R0000000001"
    var initialRange = newRangeKeyDir()
    result.saveRangeKeyDir(initialRangeKey, initialRange)
    result.ranges.add((minKey: "", maxKey: "", rangeKey: initialRangeKey))
  else:
    # Load existing ranges from Barrel1
    # For now, we'll iterate through Barrel1 keys and load them
    for rangeKey in result.barrel1.keys():
      if rangeKey.startsWith("R"):
        let serialized = result.barrel1.get(rangeKey)
        if serialized != "":
          try:
            let rkd = deserialize(serialized)
            result.ranges.add((minKey: rkd.minKey, maxKey: rkd.maxKey, rangeKey: rangeKey))
          except:
            discard
    # Sort by minKey
    result.ranges.sort(proc(a, b: auto): int = cmp(a.minKey, b.minKey))

  # Create first data file
  result.createNewDataFile()

proc close*(hb: var HugeBarrel) =
  ## Close the HugeBarrel

  # Save all cached RangeKeyDirs
  for rangeKey, rkd in hb.rangeKeyCache.cache:
    if rkd.isDirty:
      let serialized = rkd.serialize()
      discard hb.barrel1.set(rangeKey, serialized)

  # Close Barrel1
  hb.barrel1.close()

  # Close all data files
  var files = hb.barrel2Files
  for fileId in files.keys:
    var dataFile = files[fileId]
    dataFile.close()

# --- Range operations ---

proc getRangeCount*(hb: HugeBarrel): int =
  ## Get number of ranges
  hb.ranges.len

proc getRangeKeys*(hb: HugeBarrel): seq[string] =
  ## Get all range keys
  result = @[]
  for r in hb.ranges:
    result.add(r.rangeKey)

proc flushAllRanges*(hb: var HugeBarrel): int =
  ## Flush all dirty ranges to Barrel1
  var count = 0
  for rangeKey in hb.rangeKeyCache.cache.keys:
    var rkd = hb.rangeKeyCache.cache[rangeKey]
    if rkd.isDirty:
      rkd.flush()
      hb.saveRangeKeyDir(rangeKey, rkd)
      inc count
  return count
