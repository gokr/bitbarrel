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

    # Barrel2: Multiple data files (store refs for safe sharing)
    barrel2Files*: Table[uint32, ref DataFile]
    nextFileId*: uint32
    currentFileId*: uint32
    currentFileSize*: uint64
    barrel2Lock*: Lock  # Thread-safe access to barrel2Files

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

proc cacheDel*(cache: var RangeKeyDirCache, rangeKey: string) =
  ## Remove a RangeKeyDir from cache
  withLock(cache.lock):
    cache.cache.del(rangeKey)
    let index = cache.lruList.find(rangeKey)
    if index >= 0:
      cache.lruList.delete(index)

# --- Range finding ---

proc findRangeForKey*(hb: HugeBarrel, key: string): string =
  ## Find which range a key belongs to by binary search
  ## Returns rangeKey or empty string if not found

  if hb.ranges.len == 0:
    return ""

  # Binary search on ranges
  var lo = 0
  var hi = hb.ranges.len - 1

  while lo <= hi:
    let mid = (lo + hi) div 2
    let (minKey, maxKey, rangeKey) = hb.ranges[mid]

    # Handle empty bounds as wildcard (initial range)
    if (minKey.len == 0 or key >= minKey) and (maxKey.len == 0 or key <= maxKey):
      return rangeKey
    elif maxKey.len > 0 and key < minKey:
      hi = mid - 1
    else:
      lo = mid + 1

  return ""

proc addRangeMetadata(hb: var HugeBarrel, rangeKey: string, minKey: string, maxKey: string) =
  ## Add range metadata to in-memory list
  hb.ranges.add((minKey: minKey, maxKey: maxKey, rangeKey: rangeKey))
  hb.ranges.sort(proc(a, b: auto): int = cmp(a.minKey, b.minKey))

# --- Data file management ---

proc getOrCreateDataFile(hb: var HugeBarrel, fileId: uint32): ref DataFile =
  ## Get a Barrel2 file by ID, create if needed
  ## Returns a reference safely
  withLock(hb.barrel2Lock):
    if fileId in hb.barrel2Files:
      return hb.barrel2Files[fileId]

    # Create file
    let filePath = hb.path / "barrel2" / fmt"file_{fileId:06d}.data"
    createDir(hb.path / "barrel2")

    # Create DataFile and wrap in ref
    var dataFile = open(filePath, fileId, syncImmediate, false, 0, false)
    let dataFileRef = new(ref DataFile)
    dataFileRef[] = dataFile

    hb.barrel2Files[fileId] = dataFileRef
    return dataFileRef

proc createNewDataFile(hb: var HugeBarrel) =
  ## Create a new data file when current is full
  withLock(hb.barrel2Lock):
    hb.currentFileId = hb.nextFileId
    inc(hb.nextFileId)

    let filePath = hb.path / "barrel2" / fmt"file_{hb.currentFileId:06d}.data"
    createDir(hb.path / "barrel2")

    # Create DataFile and wrap in ref
    var dataFile = open(filePath, hb.currentFileId, syncImmediate, false, 0, false)
    let dataFileRef = new(ref DataFile)
    dataFileRef[] = dataFile

    hb.barrel2Files[hb.currentFileId] = dataFileRef
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

proc saveRangeMetadata(hb: var HugeBarrel) =
  ## Save range metadata to Barrel1
  ## Serializes the in-memory hb.ranges (which contains ALL range boundaries)

  # Serialize all ranges from hb.ranges (which should always be complete)
  var serialized = ""
  for r in hb.ranges:
    # Format: rangeKey\0minKey\0maxKey\0
    serialized.add(r.rangeKey)
    serialized.add('\x00')
    serialized.add(r.minKey)
    serialized.add('\x00')
    serialized.add(r.maxKey)
    serialized.add('\x00')

  discard hb.barrel1.set("__RANGES_METADATA__", serialized)

proc loadRangeMetadata(hb: var HugeBarrel) =
  ## Load range metadata from Barrel1
  ## Rebuilds hb.ranges from serialized metadata

  let serialized = hb.barrel1.get("__RANGES_METADATA__")
  if serialized == "" or serialized.len < 3:
    # No metadata saved yet
    return

  var pos = 0
  hb.ranges = @[]

  while pos < serialized.len:
    # Parse rangeKey (null-terminated)
    var rangeKeyEnd = pos
    while rangeKeyEnd < serialized.len and serialized[rangeKeyEnd] != '\x00':
      inc rangeKeyEnd
    if rangeKeyEnd >= serialized.len:
      break
    let rangeKey = serialized[pos ..< rangeKeyEnd]
    pos = rangeKeyEnd + 1

    # Parse minKey (null-terminated)
    var minKeyEnd = pos
    while minKeyEnd < serialized.len and serialized[minKeyEnd] != '\x00':
      inc minKeyEnd
    if minKeyEnd >= serialized.len:
      break
    let minKey = serialized[pos ..< minKeyEnd]
    pos = minKeyEnd + 1

    # Parse maxKey (null-terminated)
    var maxKeyEnd = pos
    while maxKeyEnd < serialized.len and serialized[maxKeyEnd] != '\x00':
      inc maxKeyEnd
    if maxKeyEnd >= serialized.len:
      break
    let maxKey = serialized[pos ..< maxKeyEnd]
    pos = maxKeyEnd + 1

    hb.ranges.add((minKey: minKey, maxKey: maxKey, rangeKey: rangeKey))

  # Sort by minKey for binary search
  hb.ranges.sort(proc(a, b: auto): int = cmp(a.minKey, b.minKey))

proc rebuildRangesFromBarrel1*(hb: var HugeBarrel) =
  ## Emergency recovery: Scan all RangeKeyDirs in barrel1 to rebuild hb.ranges
  ## Called when __RANGES_METADATA__ is missing or corrupted

  echo "WARNING: Range metadata lost, performing emergency rebuild from Barrel1..."

  hb.ranges = @[]
  var processedCount = 0

  # Iterate all keys in barrel1
  for rangeKey in hb.barrel1.keys():
    # Skip the special metadata key
    if rangeKey == "__RANGES_METADATA__":
      continue

    # Skip non-range keys (shouldn't exist but be safe)
    if not rangeKey.startsWith("R"):
      continue

    # Load the RangeKeyDir
    let serialized = hb.barrel1.get(rangeKey)
    if serialized == "":
      continue

    let rkd = deserialize(serialized)

    # Add to ranges list
    hb.ranges.add((minKey: rkd.minKey, maxKey: rkd.maxKey, rangeKey: rangeKey))
    inc(processedCount)

  # Sort by minKey for binary search
  hb.ranges.sort(proc(a, b: auto): int = cmp(a.minKey, b.minKey))

  echo fmt"Rebuilt {processedCount} ranges from Barrel1"

  # Immediately save the rebuilt metadata
  hb.saveRangeMetadata()
  echo "Saved rebuilt metadata to Barrel1"

proc saveRangeKeyDir(hb: var HugeBarrel, rangeKey: string, rkd: var RangeKeyDir) =
  ## Save a RangeKeyDir to Barrel1

  let serialized = rkd.serialize()

  let success = hb.barrel1.set(rangeKey, serialized)

  if not success:
    echo fmt"ERROR: Failed to save RangeKeyDir to Barrel1!"

  # Update cache
  hb.rangeKeyCache.cachePut(rangeKey, rkd)

  # Clear dirty flag since we just saved
  rkd.isDirty = false

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
  var dataFileRef = hb.getOrCreateDataFile(fileId)

  # Build RecordInfo
  var recordInfo: RecordInfo
  recordInfo.recordPos = entry.get().recordPos
  recordInfo.valuePos = entry.get().valuePos
  recordInfo.valueSize = entry.get().valueSize
  recordInfo.recordSize = entry.get().recordSize

  let (readKey, value, timestamp) = dataFileRef[].readRecord(recordInfo)

  return value

proc get*(hb: HugeBarrel, key: string): string =
  ## Get value for a key (const version)
  var mutableHb = hb
  result = get(mutableHb, key)

proc splitRange*(hb: var HugeBarrel, rangeKey: string): (string, string) =
  ## Split a range into two halves
  ## Returns (leftRangeKey, rightRangeKey)

  # Load the current RangeKeyDir
  var rkd = hb.loadRangeKeyDir(rangeKey)

  # Collect all entries (sorted array + pending)
  var allEntries: seq[RangeKeyDirEntry] = @[]

  # Add from sorted array
  if rkd.entryCount > 0:
    for key, entry in rkd.pairs():
      allEntries.add(entry)

  # Add from pending
  for key, entry in rkd.pendingInserts:
    allEntries.add(entry)

  # Sort by key
  allEntries.sort(proc(a, b: RangeKeyDirEntry): int = cmp(a.key, b.key))

  # Find split point (median)
  let splitIndex = allEntries.len div 2
  let splitKey = allEntries[splitIndex].key

  # Create two new RangeKeyDirs
  let leftRangeKey = fmt"R{hb.nextFileId:010d}"
  inc(hb.nextFileId)
  let rightRangeKey = fmt"R{hb.nextFileId:010d}"
  inc(hb.nextFileId)

  var leftRkd = newRangeKeyDir(allEntries[0].key, allEntries[splitIndex - 1].key)
  var rightRkd = newRangeKeyDir(allEntries[splitIndex].key, allEntries[^1].key)

  # Distribute entries
  for i, entry in allEntries:
    if i < splitIndex:
      leftRkd.insert(entry.key, entry)
    else:
      rightRkd.insert(entry.key, entry)

  # Save both to Barrel1
  hb.saveRangeKeyDir(leftRangeKey, leftRkd)
  hb.saveRangeKeyDir(rightRangeKey, rightRkd)

  # Remove old range from Barrel1
  discard hb.barrel1.delete(rangeKey)

  # Update in-memory metadata (single source of truth!)
  var newRanges: seq[tuple[minKey: string, maxKey: string, rangeKey: string]] = @[]
  for r in hb.ranges:
    if r.rangeKey != rangeKey:
      newRanges.add(r)
  newRanges.add((minKey: leftRkd.minKey, maxKey: leftRkd.maxKey, rangeKey: leftRangeKey))
  newRanges.add((minKey: rightRkd.minKey, maxKey: rightRkd.maxKey, rangeKey: rightRangeKey))
  newRanges.sort(proc(a, b: auto): int = cmp(a.minKey, b.minKey))
  hb.ranges = newRanges

  # Save updated range metadata (since hb.ranges changed)
  hb.saveRangeMetadata()

  # Update cache
  hb.rangeKeyCache.cacheDel(rangeKey)
  hb.rangeKeyCache.cachePut(leftRangeKey, leftRkd)
  hb.rangeKeyCache.cachePut(rightRangeKey, rightRkd)

  echo fmt"Split range {rangeKey} into {leftRangeKey} and {rightRangeKey}"

  result = (leftRangeKey, rightRangeKey)

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
    # Save metadata since we added a new range
    hb.saveRangeMetadata()

  # Load RangeKeyDir
  var rkd = hb.loadRangeKeyDir(rangeKey)

  # Create new file if current is too large
  let maxSize = hb.config.maxDataFileSizeMB.uint64 * 1024 * 1024
  if hb.currentFileSize > maxSize:
    hb.createNewDataFile()

  # Write to data file
  let rawTimestamp = getTime().toUnix() * 1000

  let currentFileRef = hb.getOrCreateDataFile(hb.currentFileId)
  let recordInfo = currentFileRef[].appendRecord(
    key = key,
    value = value,
    timestamp = rawTimestamp
    # Note: TTL parameter is accepted but not yet fully implemented in the storage layer
    # Future: Pass TTL to appendRecord and implement expiration checking on get()
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
  else:
    # Still need to update cache with the modified RangeKeyDir!
    # Otherwise get() will load the stale version from Barrel1
    hb.rangeKeyCache.cachePut(rangeKey, rkd)

  # Check if range needs splitting
  if rkd.len() > hb.config.maxEntriesPerRange and hb.config.autoSplitEnabled:
    # Perform range split
    discard hb.splitRange(rangeKey)

  hb.currentFileSize += recordInfo.recordSize + 4  # +4 for CRC

  return true

proc shouldSplitRange*(hb: HugeBarrel, rangeKey: string): bool =
  ## Check if a range needs to be split
  let rkd = hb.loadRangeKeyDir(rangeKey)
  result = rkd.len() > hb.config.maxEntriesPerRange

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
    barrel2Files: initTable[uint32, ref DataFile](),
    nextFileId: 2,  # Start at 2 so first file is 1
    currentFileId: 1,  # Initialize to first file ID
    currentFileSize: 0,
    ranges: @[]
  )
  initLock(result.barrel2Lock)

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
    # Add to hb.ranges (single source of truth)
    result.ranges.add((minKey: initialRange.minKey, maxKey: initialRange.maxKey, rangeKey: initialRangeKey))
    result.ranges.sort(proc(a, b: auto): int = cmp(a.minKey, b.minKey))
    # Save metadata
    result.saveRangeMetadata()
  else:
    # Load existing ranges from Barrel1
    loadRangeMetadata(result)

    if result.ranges.len == 0:
      # Metadata missing or corrupted, rebuild from barrel1
      result.rebuildRangesFromBarrel1()
    else:
      echo fmt"Loaded {result.ranges.len} ranges from Barrel1"

  # Create first data file
  result.createNewDataFile()

proc close*(hb: var HugeBarrel) =
  ## Close the HugeBarrel

  # Save all cached RangeKeyDirs (even if not dirty)
  for rangeKey, rkd in hb.rangeKeyCache.cache:
    let serialized = rkd.serialize()
    discard hb.barrel1.set(rangeKey, serialized)

  # Save range metadata (hb.ranges should already be complete and up-to-date)
  hb.saveRangeMetadata()

  # Close Barrel1
  hb.barrel1.close()

  # Close all data files
  withLock(hb.barrel2Lock):
    var files = hb.barrel2Files
    for fileId in files.keys:
      let dataFileRef = files[fileId]
      dataFileRef[].close()
    hb.barrel2Files.clear()
  deinitLock(hb.barrel2Lock)

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
