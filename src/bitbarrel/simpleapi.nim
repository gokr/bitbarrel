## BitBarrel High-Level API
##
## Provides a unified interface for key-value storage operations
## with support for multiple index modes: Normal (hash), CritBit (ordered), and Ranged (partitioned)

import std/[times, options, os]
import types
import ../storage
import ../storage/datafile
import ../storage/keydir
import ../storage/critbitindex
import ../storage/rangeindex
import ../storage/rangecache
import ../storage/rangehint

export types, datafile

type
  BarrelObj = object
    path*: string
    dataFile: DataFile
    fileId: uint32
    config: BarrelConfig
    closed: bool
    mode: BarrelMode
    # Mode-specific indexes
    keyDir: KeyDir              # Used for bmNormal
    critBit: CritBitIndex       # Used for bmCritBit
    # bmRanged fields
    rangeIndex: RangeIndex      # Range partition metadata
    rangeCache: RangeCache      # LRU cache for loaded ranges

  Barrel* = ref BarrelObj

proc defaultBarrelConfig*(): BarrelConfig =
  ## Returns default configuration for Barrel
  result = BarrelConfig(
    writeBufferSize: 64 * 1024,  # 64KB
    syncMode: UserSyncMode.Sync,
    autoCompact: true,
    compactThreshold: 0.3,
    mode: bmNormal,
    numRanges: 100,
    maxLoadedRanges: 10
  )

proc openBarrel*(path: string, fileId: uint32 = 1'u32, config: BarrelConfig = defaultBarrelConfig()): Barrel =
  ## Open a barrel with optional configuration
  result = Barrel()
  result.path = path
  result.fileId = fileId
  result.config = config
  result.mode = config.mode
  result.closed = false

  # Convert UserSyncMode to storage SyncMode
  var storageSyncMode = syncImmediate
  case config.syncMode
  of UserSyncMode.None:
    storageSyncMode = syncBuffered
  of UserSyncMode.Sync:
    storageSyncMode = syncImmediate
  of UserSyncMode.Fsync:
    storageSyncMode = syncImmediate

  result.dataFile = open(path, fileId, storageSyncMode,
                         shouldFsync = (config.syncMode == UserSyncMode.Fsync),
                         bufferSize = config.writeBufferSize)

  # Initialize index based on mode
  case config.mode
  of bmNormal:
    result.keyDir = keydir.init()
  of bmCritBit:
    result.critBit = critbitindex.init()
  of bmRanged:
    # Get data directory from path
    let dataDir = if parentDir(path) == "": "." else: parentDir(path)

    # Ensure ranges directory exists
    if not ensureRangeDir(dataDir):
      raise newException(IOError, "Failed to create ranges directory")

    # Initialize range index (for tracking metadata)
    result.rangeIndex = initRangeIndex(config.numRanges, dataDir)

    # Initialize range cache
    result.rangeCache = rangecache.init(config.maxLoadedRanges, config.numRanges, dataDir)

proc openBarrel*(path: string, config: BarrelConfig): Barrel =
  ## Open a barrel with configuration (no fileId needed)
  openBarrel(path, 1'u32, config)

proc close*(barrel: Barrel) =
  ## Close the barrel
  if not barrel.closed:
    barrel.dataFile.close()
    case barrel.mode
    of bmNormal:
      barrel.keyDir.deinit()
    of bmCritBit:
      barrel.critBit.deinit()
    of bmRanged:
      # Flush and cleanup range cache
      discard barrel.rangeCache.flushAllRanges()
      barrel.rangeCache.deinit()
      barrel.rangeIndex.deinit()
    barrel.closed = true

proc isClosed*(barrel: Barrel): bool =
  ## Check if the barrel is closed
  barrel.closed

# Helper to get entry from index (mode-independent)
proc indexGet(barrel: Barrel, key: string): Option[KeyDirEntry] =
  case barrel.mode
  of bmNormal:
    barrel.keyDir.get(key)
  of bmCritBit:
    barrel.critBit.get(key)
  of bmRanged:
    # Two-step lookup
    let rangeId = computeRangeId(key, barrel.config.numRanges)
    let rangeKeyDir = barrel.rangeCache.getOrLoadRange(rangeId)
    if rangeKeyDir.isSome():
      rangeKeyDir.get()[].get(key)
    else:
      none(KeyDirEntry)

# Helper to add entry to index (mode-independent)
proc indexAdd(barrel: Barrel, key: string, entry: KeyDirEntry) =
  case barrel.mode
  of bmNormal:
    barrel.keyDir.add(key, entry)
  of bmCritBit:
    barrel.critBit.add(key, entry)
  of bmRanged:
    # Two-step add
    let rangeId = computeRangeId(key, barrel.config.numRanges)
    let rangeKeyDir = barrel.rangeCache.getOrLoadRange(rangeId)
    if rangeKeyDir.isSome():
      rangeKeyDir.get()[].add(key, entry)
      barrel.rangeIndex.markRangeDirty(rangeId)
      barrel.rangeIndex.updateRangeKeyCount(rangeId, 1)

# Helper to get all keys from index
proc indexKeys(barrel: Barrel): seq[string] =
  case barrel.mode
  of bmNormal:
    result = barrel.keyDir.keys()
  of bmCritBit:
    result = barrel.critBit.keys()
  of bmRanged:
    # For ranged mode, we need to iterate all ranges
    # This is expensive - use with caution for large datasets
    result = @[]
    for rangeId in 0..<barrel.config.numRanges:
      let rangeKeyDir = barrel.rangeCache.getOrLoadRange(RangeId(rangeId))
      if rangeKeyDir.isSome():
        for key in rangeKeyDir.get()[].keys():
          result.add(key)

# Helper to clear index
proc indexClear(barrel: Barrel) =
  case barrel.mode
  of bmNormal:
    barrel.keyDir.clear()
  of bmCritBit:
    barrel.critBit.clear()
  of bmRanged:
    # Clear all ranges
    barrel.rangeCache.evictAll()
    barrel.rangeIndex = initRangeIndex(barrel.config.numRanges,
                                        parentDir(barrel.path))

# Helper to get index length
proc indexLen(barrel: Barrel): int =
  case barrel.mode
  of bmNormal:
    barrel.keyDir.len()
  of bmCritBit:
    barrel.critBit.len()
  of bmRanged:
    # Get total from range index metadata
    barrel.rangeIndex.getTotalKeys().int

proc set*(barrel: Barrel, key: string, value: string): bool =
  ## Set a key-value pair
  if barrel.closed:
    return false

  let timestamp = getTime().toUnix()
  try:
    let info = barrel.dataFile.appendRecord(key, value, timestamp)
    let entry = KeyDirEntry(
      fileId: barrel.fileId,
      recordPos: info.recordPos,
      valuePos: info.valuePos,
      valueSize: info.valueSize,
      timestamp: timestamp,
      recordSize: info.recordSize
    )
    barrel.indexAdd(key, entry)
    return true
  except:
    return false

proc get*(barrel: Barrel, key: string): string =
  ## Get a value by key (returns empty string if not found)
  if barrel.closed:
    return ""

  let found = barrel.indexGet(key)
  if found.isSome():
    let entry = found.get()
    let recordInfo = RecordInfo(
      recordPos: entry.recordPos,
      valuePos: entry.valuePos,
      valueSize: entry.valueSize,
      recordSize: entry.recordSize
    )
    try:
      let (_, value, _) = barrel.dataFile.readRecord(recordInfo)
      return value
    except:
      return ""
  else:
    return ""

proc delete*(barrel: Barrel, key: string): bool =
  ## Delete a key (using tombstone)
  if barrel.closed:
    return false

  let timestamp = getTime().toUnix()
  try:
    # Write empty value as tombstone
    let info = barrel.dataFile.appendRecord(key, "", timestamp)
    let entry = KeyDirEntry(
      fileId: barrel.fileId,
      recordPos: info.recordPos,
      valuePos: info.valuePos,
      valueSize: info.valueSize,
      timestamp: timestamp,
      recordSize: info.recordSize
    )
    barrel.indexAdd(key, entry)
    return true
  except:
    return false

proc exists*(barrel: Barrel, key: string): bool =
  ## Check if a key exists (and is not deleted)
  if barrel.closed:
    return false

  let found = barrel.indexGet(key)
  if found.isSome():
    let entry = found.get()
    let recordInfo = RecordInfo(
      recordPos: entry.recordPos,
      valuePos: entry.valuePos,
      valueSize: entry.valueSize,
      recordSize: entry.recordSize
    )
    try:
      let (_, value, _) = barrel.dataFile.readRecord(recordInfo)
      return value.len > 0
    except:
      return false
  return false

proc count*(barrel: Barrel): int =
  ## Get number of non-deleted keys in store
  if barrel.closed:
    return 0

  var count = 0
  let keys = barrel.indexKeys()
  for key in keys:
    let found = barrel.indexGet(key)
    if found.isSome():
      let entry = found.get()
      let recordInfo = RecordInfo(
        recordPos: entry.recordPos,
        valuePos: entry.valuePos,
        valueSize: entry.valueSize,
        recordSize: entry.recordSize
      )
      try:
        let (_, value, _) = barrel.dataFile.readRecord(recordInfo)
        if value.len > 0:
          inc count
      except:
        discard
  return count

proc listKeys*(barrel: Barrel): seq[string] =
  ## List all non-deleted keys in the store
  result = @[]
  if barrel.closed:
    return

  let keys = barrel.indexKeys()
  for key in keys:
    let found = barrel.indexGet(key)
    if found.isSome():
      let entry = found.get()
      let recordInfo = RecordInfo(
        recordPos: entry.recordPos,
        valuePos: entry.valuePos,
        valueSize: entry.valueSize,
        recordSize: entry.recordSize
      )
      try:
        let (_, value, _) = barrel.dataFile.readRecord(recordInfo)
        if value.len > 0:
          result.add(key)
      except:
        discard

proc clear*(barrel: Barrel): bool =
  ## Clear all keys (values remain in file but won't be accessible)
  if barrel.closed:
    return false

  try:
    barrel.indexClear()
    return true
  except:
    return false

# CritBit mode specific operations (range queries)

proc keysWithPrefix*(barrel: Barrel, prefix: string): seq[string] =
  ## Get all keys that start with the given prefix (sorted)
  ## Only efficient in bmCritBit mode
  if barrel.closed:
    return @[]

  case barrel.mode
  of bmCritBit:
    result = barrel.critBit.keysWithPrefix(prefix)
  else:
    # For non-CritBit modes, fall back to filtering all keys
    result = @[]
    for key in barrel.indexKeys():
      if key.len >= prefix.len and key[0..<prefix.len] == prefix:
        result.add(key)

proc keysInRange*(barrel: Barrel, startKey: string, endKey: string): seq[string] =
  ## Get all keys in the range [startKey, endKey) (sorted)
  ## Only efficient in bmCritBit mode
  if barrel.closed:
    return @[]

  case barrel.mode
  of bmCritBit:
    result = barrel.critBit.keysInRange(startKey, endKey)
  else:
    # For non-CritBit modes, fall back to filtering all keys
    result = @[]
    for key in barrel.indexKeys():
      if key >= startKey and key < endKey:
        result.add(key)

proc countWithPrefix*(barrel: Barrel, prefix: string): int =
  ## Count keys with given prefix
  if barrel.closed:
    return 0

  case barrel.mode
  of bmCritBit:
    result = barrel.critBit.countWithPrefix(prefix)
  else:
    result = 0
    for key in barrel.indexKeys():
      if key.len >= prefix.len and key[0..<prefix.len] == prefix:
        inc result

# Utility functions

proc getMode*(barrel: Barrel): BarrelMode =
  ## Get the index mode of the barrel
  barrel.mode

proc getConfig*(barrel: Barrel): BarrelConfig =
  ## Get the configuration of the barrel
  barrel.config

proc getPath*(barrel: Barrel): string =
  ## Get the data file path
  barrel.path

proc indexCount*(barrel: Barrel): int =
  ## Get the number of entries in the index (including tombstones)
  barrel.indexLen()

# Ranged mode specific operations

proc flushRanges*(barrel: Barrel): int =
  ## Flush all dirty ranges to disk (only for bmRanged mode)
  ## Returns number of ranges flushed
  if barrel.closed or barrel.mode != bmRanged:
    return 0
  barrel.rangeCache.flushAllRanges()

proc loadedRangeCount*(barrel: Barrel): int =
  ## Get number of currently loaded ranges (only for bmRanged mode)
  if barrel.mode != bmRanged:
    return 0
  barrel.rangeCache.stats().loaded

proc rangeStats*(barrel: Barrel): tuple[loaded: int, maxRanges: int, totalKeys: int64] =
  ## Get range statistics (only for bmRanged mode)
  if barrel.mode != bmRanged:
    return (0, 0, 0'i64)
  let cacheStats = barrel.rangeCache.stats()
  (loaded: cacheStats.loaded,
   maxRanges: cacheStats.maxRanges,
   totalKeys: barrel.rangeIndex.getTotalKeys())

# Backward compatibility aliases (deprecated, will be removed)
type
  SimpleBB* {.deprecated: "Use Barrel instead".} = Barrel
  SimpleConfig* {.deprecated: "Use BarrelConfig instead".} = BarrelConfig

proc defaultConfig*(): BarrelConfig {.deprecated: "Use defaultBarrelConfig instead".} =
  defaultBarrelConfig()

proc open*(path: string, fileId: uint32 = 1'u32, config: BarrelConfig = defaultBarrelConfig()): Barrel {.deprecated: "Use openBarrel instead".} =
  openBarrel(path, fileId, config)

proc open*(path: string, config: BarrelConfig): Barrel {.deprecated: "Use openBarrel instead".} =
  openBarrel(path, config)
