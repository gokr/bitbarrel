## HugeBarrel - Two-tier storage for massive datasets
##
## Coordinates between Barrel1 (CritBit for RangeKeyDirs) and Barrel2 (data files)

import std/[tables, options, os, strformat, strutils, algorithm, locks, times, endians]
import ../bitbarrel/types
import ../bitbarrel/barrel
import ../storage/datafile
import rangekeydir
import crc32

const
  DEFAULT_RANGE_CACHE_SIZE = 10
  PENDING_SPLIT_KEY* = "__PENDING_SPLIT__"

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

    # Time-based flush tracking
    lastFlushTime*: float  # Last flush time (cpuTime() * 1000)

# Forward declarations for functions used before they're defined
proc shouldTimeFlush*(hb: HugeBarrel): bool
proc splitRangeAtomic*(hb: var HugeBarrel, rangeKey: string): (string, string)
proc recoverPendingSplit*(hb: var HugeBarrel)
proc rebuildFromBarrel2*(hb: var HugeBarrel, options: Barrel2RecoveryOptions = Barrel2RecoveryOptions()): Barrel2RecoveryStats
proc flushDirtyRanges*(hb: var HugeBarrel): int

proc initRangeKeyDirCache(maxSize: int): RangeKeyDirCache =
  ## Initialize LRU cache for RangeKeyDirs
  result.cache = initTable[string, RangeKeyDir]()
  result.lruList = @[]
  result.maxSize = maxSize
  initLock(result.lock)

proc evictLRU(cache: var RangeKeyDirCache): tuple[rangeKey: string, rkd: RangeKeyDir, wasDirty: bool] =
  ## Evict least recently used RangeKeyDir
  ## Returns the evicted data so caller can save if dirty
  if cache.lruList.len == 0:
    return ("", newRangeKeyDir(), false)

  let oldestKey = cache.lruList[0]

  # Safety check: key might have been manually deleted from cache
  if oldestKey notin cache.cache:
    # Just remove from LRU list and try next
    cache.lruList.delete(0)
    return ("", newRangeKeyDir(), false)

  let evictedRkd = cache.cache[oldestKey]
  let wasDirty = evictedRkd.isDirty
  cache.lruList.delete(0)
  cache.cache.del(oldestKey)
  return (oldestKey, evictedRkd, wasDirty)

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

proc cachePut(hb: var HugeBarrel, rangeKey: string, rkd: RangeKeyDir) =
  ## Put RangeKeyDir in cache with automatic eviction
  withLock(hb.rangeKeyCache.lock):
    # Check if key already exists in cache (update in place)
    if rangeKey in hb.rangeKeyCache.cache:
      # Update existing entry and move to end of LRU (most recently used)
      hb.rangeKeyCache.cache[rangeKey] = rkd
      let index = hb.rangeKeyCache.lruList.find(rangeKey)
      if index >= 0:
        hb.rangeKeyCache.lruList.delete(index)
        hb.rangeKeyCache.lruList.add(rangeKey)
      return

    # Key is new - evict if at capacity
    while hb.rangeKeyCache.lruList.len >= hb.rangeKeyCache.maxSize:
      let (evictedKey, evictedRkd, wasDirty) = hb.rangeKeyCache.evictLRU()
      # If we got a stale entry (key not in cache), keep evicting
      if evictedKey == "":
        continue
      # Save evicted range if it was dirty
      if wasDirty:
        let evictedSerialized = evictedRkd.serialize()
        discard hb.barrel1.set(evictedKey, evictedSerialized)
      break  # Successfully evicted a real entry

    # Add new entry to cache and LRU list
    hb.rangeKeyCache.cache[rangeKey] = rkd
    hb.rangeKeyCache.lruList.add(rangeKey)

proc cacheClear*(cache: var RangeKeyDirCache) =
  ## Clear the cache
  withLock(cache.lock):
    cache.cache.clear()
    cache.lruList = @[]

proc cacheDel*(cache: var RangeKeyDirCache, rangeKey: string) =
  ## Remove a RangeKeyDir from cache
  withLock(cache.lock):
    cache.cache.del(rangeKey)
    # Remove ALL occurrences from LRU list (shouldn't be duplicates, but just in case)
    var index = cache.lruList.find(rangeKey)
    while index >= 0:
      cache.lruList.delete(index)
      index = cache.lruList.find(rangeKey)

# --- Range finding ---

proc findRangeForKey*(hb: HugeBarrel, key: string): string =
  ## Find which range a key belongs to by binary search
  ## Returns rangeKey or empty string if not found
  ##
  ## Range semantics:
  ## - Empty minKey: matches any key (initial wildcard range)
  ## - Empty maxKey: matches any key >= minKey (no upper bound)
  ## - All ranges use inclusive bounds: [minKey, maxKey]

  if hb.ranges.len == 0:
    return ""

  # Binary search on ranges
  var lo = 0
  var hi = hb.ranges.len - 1

  while lo <= hi:
    let mid = (lo + hi) div 2
    let (minKey, maxKey, rangeKey) = hb.ranges[mid]

    # Empty minKey - wildcard that matches anything
    if minKey.len == 0:
      return rangeKey

    # Check if key is within this range's bounds
    # Use inclusive comparison: minKey <= key <= maxKey
    if key >= minKey:
      # Key is >= minKey, now check if it's <= maxKey (or maxKey is empty = no upper bound)
      if maxKey.len == 0 or key <= maxKey:
        return rangeKey
      else:
        # Key > maxKey, search right half
        lo = mid + 1
    else:
      # Key < minKey, search left half
      hi = mid - 1

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
  hb.cachePut(rangeKey, rkd)

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

  let success = hb.barrel1.set("__RANGES_METADATA__", serialized)
  if not success:
    raise newException(IOError, fmt"Failed to save range metadata to Barrel1")

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

  # Iterate all range keys in barrel1 using listKeys() method
  let allKeys = hb.barrel1.listKeys(limit = 100000)  # Get up to 100K keys
  for rangeKey in allKeys:
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
    raise newException(IOError, fmt("Failed to save RangeKeyDir {rangeKey} to Barrel1"))

  # Update cache - let cachePut handle eviction and save
  hb.cachePut(rangeKey, rkd)

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

  let (_, value, _) = dataFileRef[].readRecord(recordInfo)
  return value

proc get*(hb: HugeBarrel, key: string): string =
  ## Get value for a key (const version)
  var mutableHb = hb
  result = get(mutableHb, key)

proc flushAllCachedRanges*(hb: var HugeBarrel): int =
  ## Flush all dirty cached ranges to Barrel1
  ## Only iterates over cached ranges (more efficient than flushDirtyRanges)
  var count = 0
  for rangeKey in hb.rangeKeyCache.cache.keys:
    var rkd = hb.rangeKeyCache.cache[rangeKey]
    if rkd.isDirty:
      rkd.flush()
      hb.saveRangeKeyDir(rangeKey, rkd)
      inc count
  return count

proc splitRange*(hb: var HugeBarrel, rangeKey: string): (string, string) =
  ## Split a range into two halves
  ## Returns (leftRangeKey, rightRangeKey)

  # Before splitting, save all dirty cached ranges to prevent data loss during eviction
  discard hb.flushAllCachedRanges()

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

  # Update cache by saving the new ranges
  hb.rangeKeyCache.cacheDel(rangeKey)
  hb.saveRangeKeyDir(leftRangeKey, leftRkd)
  hb.saveRangeKeyDir(rightRangeKey, rightRkd)

  result = (leftRangeKey, rightRangeKey)

proc set*(hb: var HugeBarrel, key: string, value: string, ttl: int = -1): bool =
  ## Set a key-value pair

  if hb.barrel1.isClosed():
    return false

  # Find or create range for this key
  var rangeKey = hb.findRangeForKey(key)

  if rangeKey == "":
    # Create new range
    rangeKey = fmt("R{hb.nextFileId:010d}")
    inc(hb.nextFileId)
    var newRange = newRangeKeyDir(key, key)
    hb.saveRangeKeyDir(rangeKey, newRange)
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

  # Save RangeKeyDir if buffer is full OR time-based flush is due
  if rkd.shouldFlush() or hb.shouldTimeFlush():
    rkd.flush()
    hb.saveRangeKeyDir(rangeKey, rkd)
    hb.lastFlushTime = cpuTime() * 1000
  else:
    # Update cache with the modified RangeKeyDir!
    hb.cachePut(rangeKey, rkd)

  # Check if range needs splitting
  if rkd.len() > hb.config.maxEntriesPerRange and hb.config.autoSplitEnabled:
    # Perform atomic range split (with crash recovery marker)
    discard hb.splitRangeAtomic(rangeKey)

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
    ranges: @[],
    lastFlushTime: cpuTime() * 1000  # Initialize flush time
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

    # Recover any interrupted split operations
    result.recoverPendingSplit()

    # Run Barrel2 recovery if enabled (recovers orphaned records)
    if config.hugeConfig.enableBarrel2Recovery:
      let recoveryOpts = Barrel2RecoveryOptions(
        validateChecksums: config.validateCrc,
        skipCorruptRecords: true,
        maxProgressInterval: 10000,
        enableVerboseLogging: false
      )
      let stats = result.rebuildFromBarrel2(recoveryOpts)
      if stats.recoveredRecords > 0:
        echo fmt"Recovered {stats.recoveredRecords} orphaned records from Barrel2"

  # Create first data file
  result.createNewDataFile()

proc close*(hb: var HugeBarrel) =
  ## Close the HugeBarrel

  # First, flush ALL dirty ranges (not just cached ones)
  # This ensures data in ranges that were never loaded into cache is also saved
  discard hb.flushDirtyRanges()

  # Save all cached RangeKeyDirs (even if not dirty)
  for rangeKey in hb.rangeKeyCache.cache.keys:
    var rkd = hb.rangeKeyCache.cache[rangeKey]
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

proc flushDirtyRanges*(hb: var HugeBarrel): int =
  ## Flush all dirty ranges to Barrel1
  ## Iterates over ALL ranges (not just cached ones) to ensure complete persistence
  var count = 0
  for r in hb.ranges:
    var rkd = hb.loadRangeKeyDir(r.rangeKey)  # Load from cache or Barrel1
    if rkd.isDirty:
      rkd.flush()
      hb.saveRangeKeyDir(r.rangeKey, rkd)
      inc count
  return count

# --- Time-based flush ---

proc shouldTimeFlush*(hb: HugeBarrel): bool =
  ## Check if time-based flush is needed
  if hb.config.flushIntervalMs <= 0:
    return false
  let now = cpuTime() * 1000
  let elapsed = now - hb.lastFlushTime
  return elapsed >= hb.config.flushIntervalMs.float

proc flushIfNeeded*(hb: var HugeBarrel) =
  ## Flush dirty ranges if time threshold exceeded
  if hb.shouldTimeFlush():
    discard hb.flushDirtyRanges()
    hb.lastFlushTime = cpuTime() * 1000

# --- Barrel2 Recovery ---

proc scanBarrel2Files*(hb: HugeBarrel): seq[string] =
  ## Scan barrel2 directory for data files
  ## Returns sorted list of file paths (by file ID)
  result = @[]
  let barrel2Dir = hb.path / "barrel2"

  if not dirExists(barrel2Dir):
    return

  for kind, path in walkDir(barrel2Dir):
    if kind == pcFile and path.endsWith(".data"):
      # Validate filename format: file_NNNNNN.data
      let filename = extractFilename(path)
      if filename.startsWith("file_") and filename.len == 17:
        result.add(path)

  # Sort by file ID (numeric order)
  result.sort(proc(a, b: string): int =
    let aName = extractFilename(a)
    let bName = extractFilename(b)
    let aId = parseInt(aName[5..10])
    let bId = parseInt(bName[5..10])
    cmp(aId, bId)
  )

proc extractFileId*(filePath: string): uint32 =
  ## Extract file ID from barrel2 file path
  ## file_000001.data -> 1
  let filename = extractFilename(filePath)
  if filename.startsWith("file_") and filename.len == 17:
    return parseInt(filename[5..10]).uint32
  return 0

proc readRecordForRecovery*(filePath: string, offset: int64, validateCrc: bool = true):
    tuple[key: string, timestamp: int64, valueSize: uint32, recordSize: uint32, deleted: bool, valid: bool] =
  ## Read minimal record info for recovery scanning
  ## Returns (key, timestamp, valueSize, recordSize, deleted, valid)
  ## This is optimized to read only what's needed for index recovery
  result.valid = false

  let fileSize = getFileSize(filePath)
  if offset < 0 or offset >= fileSize:
    return

  let readFile = open(filePath, fmRead)
  defer: readFile.close()

  readFile.setFilePos(offset, fspSet)

  # Read CRC32 (4 bytes)
  var storedCrc: uint32
  let crcBytesRead = readFile.readBuffer(addr storedCrc, 4)
  if crcBytesRead != 4:
    return

  # Read timestamp (8 bytes, little-endian)
  var rawTimestamp: int64
  let tsBytesRead = readFile.readBuffer(addr rawTimestamp, 8)
  if tsBytesRead != 8:
    return
  littleEndian64(addr result.timestamp, addr rawTimestamp)

  # Read key length (4 bytes, little-endian)
  var rawKeyLen: uint32
  let keyLenRead = readFile.readBuffer(addr rawKeyLen, 4)
  if keyLenRead != 4:
    return
  var keyLen: uint32
  littleEndian32(addr keyLen, addr rawKeyLen)

  # Validate key length
  if keyLen > MAX_KEY_SIZE.uint32:
    return

  # Read key
  result.key = newString(keyLen.int)
  if keyLen > 0:
    let keyRead = readFile.readBuffer(addr result.key[0], keyLen.int)
    if keyRead != keyLen.int:
      return

  # Read value length (4 bytes, little-endian)
  var rawValueLen: uint32
  let valueLenRead = readFile.readBuffer(addr rawValueLen, 4)
  if valueLenRead != 4:
    return
  littleEndian32(addr result.valueSize, addr rawValueLen)

  # Validate value length
  if result.valueSize > MAX_VALUE_SIZE.uint32:
    return

  # Read flags (1 byte) and algorithm (1 byte)
  var flags: uint8
  var algo: uint8
  if readFile.readBuffer(addr flags, 1) != 1:
    return
  if readFile.readBuffer(addr algo, 1) != 1:
    return

  # Calculate total record size: CRC(4) + timestamp(8) + keyLen(4) + key + valueLen(4) + flags(1) + algo(1) + value
  result.recordSize = (4 + 8 + 4 + keyLen.int + 4 + 1 + 1 + result.valueSize.int).uint32

  # Check if value is a tombstone (deleted)
  result.deleted = result.valueSize == 0

  # Validate CRC32 if requested
  if validateCrc:
    # Read the full record data for CRC verification
    let recordDataLen = result.recordSize.int - 4  # Exclude CRC itself
    readFile.setFilePos(offset + 4, fspSet)  # Position after CRC
    var recordData = newString(recordDataLen)
    let bytesRead = readFile.readBuffer(addr recordData[0], recordDataLen)
    if bytesRead != recordDataLen:
      return
    let computedCrc = crc32(recordData)
    if storedCrc != computedCrc:
      return  # CRC mismatch, invalid record

  result.valid = true

proc rebuildFromBarrel2*(hb: var HugeBarrel, options: Barrel2RecoveryOptions = Barrel2RecoveryOptions()): Barrel2RecoveryStats =
  ## Full recovery from Barrel2 data files
  ## Scans all records and rebuilds any missing RangeKeyDir entries
  result = Barrel2RecoveryStats()
  let startTime = cpuTime()

  # Step 1: Scan data files
  let dataFiles = hb.scanBarrel2Files()
  result.filesScanned = dataFiles.len

  if dataFiles.len == 0:
    return

  if options.enableVerboseLogging:
    echo fmt("Barrel2 recovery: scanning {dataFiles.len} data files")

  # Step 2: Build recovery map
  # Map: rangeKey -> Table[key, RangeKeyDirEntry]
  var recoveryMap = initTable[string, Table[string, RangeKeyDirEntry]]()

  for filePath in dataFiles:
    let fileId = extractFileId(filePath)
    var offset = HEADER_SIZE.int64  # Skip file header
    let fileSize = getFileSize(filePath)

    while offset < fileSize:
      let (key, timestamp, valueSize, recordSize, deleted, valid) =
        readRecordForRecovery(filePath, offset, options.validateChecksums)

      if not valid:
        if options.skipCorruptRecords:
          inc result.corruptRecords
          # Try to find next valid record by scanning forward
          offset += 1
          continue
        else:
          raise newException(IOError, fmt("Corrupt record at {filePath}:{offset}"))

      inc result.totalRecords
      inc result.validRecords
      result.bytesScanned += recordSize.int64

      # Check if this is a tombstone
      if deleted:
        inc result.tombstoneRecords

      # Find or create target range
      var rangeKey = hb.findRangeForKey(key)
      if rangeKey == "":
        # Key doesn't fit in any existing range - create new range
        rangeKey = fmt"R{hb.nextFileId:010d}"
        inc hb.nextFileId
        hb.addRangeMetadata(rangeKey, key, key)
        inc result.rangesCreated

      # Check if this record is newer than what we have indexed
      let rkd = hb.loadRangeKeyDir(rangeKey)
      let existing = rkd.find(key)

      var shouldAdd = false
      if existing.isNone():
        shouldAdd = true
        inc result.orphanedRecords
      elif existing.get().timestamp < timestamp:
        # Record in Barrel2 is newer than what's indexed
        shouldAdd = true
        inc result.orphanedRecords

      if shouldAdd:
        # Calculate valuePos: CRC(4) + timestamp(8) + keyLen(4) + key + valueLen(4) + flags(1) + algo(1)
        let valuePos = offset.uint64 + 4 + 8 + 4 + key.len.uint64 + 4 + 1 + 1

        # Build entry for recovery
        let entry = RangeKeyDirEntry(
          key: key,
          fileId: fileId,
          recordPos: offset.uint64 + 4,  # After CRC
          valuePos: valuePos,
          valueSize: valueSize,
          timestamp: timestamp,
          recordSize: recordSize,
          deleted: deleted
        )

        if rangeKey notin recoveryMap:
          recoveryMap[rangeKey] = initTable[string, RangeKeyDirEntry]()

        # Keep newest entry for each key
        if key notin recoveryMap[rangeKey] or
           recoveryMap[rangeKey][key].timestamp < timestamp:
          recoveryMap[rangeKey][key] = entry

      # Report progress
      if options.maxProgressInterval > 0 and result.totalRecords mod options.maxProgressInterval == 0:
        echo fmt("Barrel2 recovery progress: {result.totalRecords} records scanned")

      offset += recordSize.int64

  # Step 3: Apply recovery to RangeKeyDirs
  for rangeKey, entries in recoveryMap:
    var rkd = hb.loadRangeKeyDir(rangeKey)

    for key, entry in entries:
      rkd.insert(key, entry)
      inc result.recoveredRecords

    rkd.flush()
    hb.saveRangeKeyDir(rangeKey, rkd)
    inc result.rangesUpdated

  # Step 4: Save updated metadata
  if result.recoveredRecords > 0:
    hb.saveRangeMetadata()

  result.recoveryTimeMs = ((cpuTime() - startTime) * 1000).int64

  if options.enableVerboseLogging or result.recoveredRecords > 0:
    echo fmt("Barrel2 recovery complete: {result.recoveredRecords} records recovered from {result.filesScanned} files in {result.recoveryTimeMs}ms")

# --- Atomic Split with Pending Marker ---

proc serializePendingSplit(ps: PendingSplit): string =
  ## Serialize PendingSplit to string format
  result = ps.oldRangeKey & "\x00" & ps.leftRangeKey & "\x00" & ps.rightRangeKey & "\x00"
  var tsBytes: array[8, byte]
  var ts = ps.timestamp
  littleEndian64(addr tsBytes[0], addr ts)
  for b in tsBytes:
    result.add(char(b))

proc deserializePendingSplit(data: string): PendingSplit =
  ## Deserialize PendingSplit from string format
  var pos = 0

  # Parse oldRangeKey
  var endPos = data.find('\x00', pos)
  if endPos < 0: return
  result.oldRangeKey = data[pos ..< endPos]
  pos = endPos + 1

  # Parse leftRangeKey
  endPos = data.find('\x00', pos)
  if endPos < 0: return
  result.leftRangeKey = data[pos ..< endPos]
  pos = endPos + 1

  # Parse rightRangeKey
  endPos = data.find('\x00', pos)
  if endPos < 0: return
  result.rightRangeKey = data[pos ..< endPos]
  pos = endPos + 1

  # Parse timestamp (8 bytes, little-endian)
  if pos + 8 > data.len: return
  var tsBytes: array[8, byte]
  for i in 0..7:
    tsBytes[i] = byte(data[pos + i])
  littleEndian64(addr result.timestamp, addr tsBytes[0])

proc recoverPendingSplit*(hb: var HugeBarrel) =
  ## Called during open to complete interrupted splits
  let pendingData = hb.barrel1.get(PENDING_SPLIT_KEY)
  if pendingData == "":
    return  # No pending split

  echo "Found pending split marker, recovering..."
  let pending = deserializePendingSplit(pendingData)

  # Check what state we're in
  let leftExists = hb.barrel1.get(pending.leftRangeKey) != ""
  let rightExists = hb.barrel1.get(pending.rightRangeKey) != ""
  let oldExists = hb.barrel1.get(pending.oldRangeKey) != ""

  if leftExists and rightExists:
    # Split completed, just clean up
    if oldExists:
      discard hb.barrel1.delete(pending.oldRangeKey)
    # Rebuild metadata from Barrel1
    hb.rebuildRangesFromBarrel1()
    echo fmt("Recovered completed split: {pending.oldRangeKey} -> {pending.leftRangeKey}, {pending.rightRangeKey}")
  else:
    # Split incomplete - restore from old range
    # Old range should still have all data
    echo fmt("Recovering incomplete split of {pending.oldRangeKey}")
    if leftExists:
      discard hb.barrel1.delete(pending.leftRangeKey)
    if rightExists:
      discard hb.barrel1.delete(pending.rightRangeKey)

  # Clear marker
  discard hb.barrel1.delete(PENDING_SPLIT_KEY)

proc splitRangeAtomic*(hb: var HugeBarrel, rangeKey: string): (string, string) =
  ## Atomic split with recovery marker
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

  # Guard: Don't split if we don't have enough entries
  if allEntries.len < 2:
    echo fmt"Warning: Cannot split range {rangeKey} with only {allEntries.len} entries"
    return ("", "")

  # Find split point (median)
  let splitIndex = allEntries.len div 2

  # Guard: Ensure splitIndex is valid
  if splitIndex <= 0 or splitIndex >= allEntries.len:
    echo fmt"Warning: Invalid split index {splitIndex} for {allEntries.len} entries"
    return ("", "")

  # Create new range keys
  let leftRangeKey = fmt"R{hb.nextFileId:010d}"
  inc(hb.nextFileId)
  let rightRangeKey = fmt"R{hb.nextFileId:010d}"
  inc(hb.nextFileId)

  # Step 1: Write pending split marker FIRST (for atomicity)
  let pendingSplit = PendingSplit(
    oldRangeKey: rangeKey,
    leftRangeKey: leftRangeKey,
    rightRangeKey: rightRangeKey,
    timestamp: getTime().toUnix()
  )
  discard hb.barrel1.set(PENDING_SPLIT_KEY, serializePendingSplit(pendingSplit))

  # Step 2: Create and populate new RangeKeyDirs
  # Use inclusive bounds for all ranges: [minKey, maxKey]
  # Left range gets entries [0..splitIndex-1]
  # Right range gets entries [splitIndex..end]
  var leftRkd = newRangeKeyDir(allEntries[0].key, allEntries[splitIndex - 1].key)
  var rightRkd = newRangeKeyDir(allEntries[splitIndex].key, allEntries[^1].key)

  # Distribute entries
  for i, entry in allEntries:
    if i < splitIndex:
      leftRkd.insert(entry.key, entry)
    else:
      rightRkd.insert(entry.key, entry)

  # Step 3: Save both new RangeKeyDirs to Barrel1
  hb.saveRangeKeyDir(leftRangeKey, leftRkd)
  hb.saveRangeKeyDir(rightRangeKey, rightRkd)

  # Step 4: Update in-memory metadata with new ranges
  var newRanges: seq[tuple[minKey: string, maxKey: string, rangeKey: string]] = @[]
  for r in hb.ranges:
    if r.rangeKey != rangeKey:
      newRanges.add(r)
  # Use the explicit min/max we set, not from RangeKeyDir which might be empty
  newRanges.add((minKey: allEntries[0].key, maxKey: allEntries[splitIndex - 1].key, rangeKey: leftRangeKey))
  newRanges.add((minKey: allEntries[splitIndex].key, maxKey: allEntries[^1].key, rangeKey: rightRangeKey))
  newRanges.sort(proc(a, b: tuple[minKey: string, maxKey: string, rangeKey: string]): int = cmp(a.minKey, b.minKey))
  hb.ranges = newRanges

  # Step 5: Save updated range metadata
  hb.saveRangeMetadata()

  # Step 6: Delete old range from Barrel1
  discard hb.barrel1.delete(rangeKey)

  # Step 7: Clear pending marker (split complete)
  discard hb.barrel1.delete(PENDING_SPLIT_KEY)

  # Update cache
  hb.rangeKeyCache.cacheDel(rangeKey)
  hb.cachePut(leftRangeKey, leftRkd)
  hb.cachePut(rightRangeKey, rightRkd)

  echo fmt"Split range {rangeKey} into {leftRangeKey} and {rightRangeKey}"

  result = (leftRangeKey, rightRangeKey)
