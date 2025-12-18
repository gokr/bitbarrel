## BitBarrel High-Level API
##
## Provides a unified interface for key-value storage operations
## with support for multiple index modes: Hash, CritBit (ordered), and HugeCritBit (massive datasets)

import std/[times, options, os, strformat, strutils]
import types
import ../storage
import ../storage/datafile
import ../storage/keydir
import ../storage/critbitindex
import ../storage/record
import ../storage/compact

export types, datafile

type
  BarrelObj = object
    path*: string
    dataFile: DataFile
    fileId: uint32
    config*: BarrelConfig
    closed: bool
    mode: BarrelMode
    # Mode-specific indexes
    keyDir: KeyDir              # Used for bmHash
    critBit: CritBitIndex       # Used for bmCritBit
    # TODO: hugeBarrel for bmHugeCritBit (Phase 3)
    # Compaction
    compactController: CompactController  # Background compaction worker

  Barrel* = ref BarrelObj

proc defaultBarrelConfig*(): BarrelConfig =
  ## Returns default configuration for Barrel
  result = BarrelConfig(
    writeBufferSize: 64 * 1024,  # 64KB
    syncMode: UserSyncMode.Sync,
    autoCompact: true,
    compactThreshold: 0.3,
    validateCrc: true,  # Validate CRC32 on reads (see docs/CRC.md)
    defaultTtl: 0,              # No expiration by default
    checkExpirationOnRead: true,  # Check and ignore expired records
    deleteExpiredOnRead: false,  # Don't automatically write tombstones
    mode: bmHash,               # Default to hash mode
    hugeConfig: HugeBarrelConfig(
      maxEntriesPerRange: 100_000,
      rangeCacheSize: 10,
      maxDataFileSizeMB: 1024,
      autoSplitEnabled: true
    )
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
                         bufferSize = config.writeBufferSize,
                         validateCrc = config.validateCrc)

  # Initialize index based on mode
  case config.mode
  of bmHash:
    result.keyDir = keydir.init()
  of bmCritBit:
    result.critBit = critbitindex.init()
  of bmHugeCritBit:
    # TODO: Initialize HugeBarrel (Phase 3)
    raise newException(ValueError, "bmHugeCritBit mode not yet implemented")

  # Initialize compaction
  if config.autoCompact:
    # Create CompactConfig from BarrelConfig settings
    var compactConfig: CompactConfig
    compactConfig.enabled = true
    compactConfig.maxFileSize = 1024 * 1024 * 1024  # 1GB default
    compactConfig.triggerThreshold = config.compactThreshold
    compactConfig.compactInterval = 60  # 1 minute
    compactConfig.compactIntervalBytes = 10 * 1024 * 1024  # 10MB

    # Initialize with appropriate index based on mode
    case config.mode
    of bmHash:
      result.compactController = newCompactController(compactConfig, result.keyDir)
    of bmCritBit:
      result.compactController = newCompactController(compactConfig, result.critBit)
    of bmHugeCritBit:
      # TODO: HugeBarrel compaction (Phase 5)
      result.compactController = nil

    # Set barrel path for auto-compaction
    if result.compactController != nil:
      let dataDir = if parentDir(path) == "": "." else: parentDir(path)
      result.compactController.setBarrelPath(dataDir)

      # Start background worker
      result.compactController.startCompactWorker()
  else:
    result.compactController = nil

proc openBarrel*(path: string, config: BarrelConfig): Barrel =
  ## Open a barrel with configuration (no fileId needed)
  openBarrel(path, 1'u32, config)

proc close*(barrel: Barrel) =
  ## Close the barrel
  if not barrel.closed:
    barrel.dataFile.close()
    case barrel.mode
    of bmHash:
      barrel.keyDir.deinit()
    of bmCritBit:
      barrel.critBit.deinit()
    of bmHugeCritBit:
      # TODO: Close HugeBarrel (Phase 3)
      discard

    # Stop compaction worker
    if barrel.compactController != nil:
      barrel.compactController.shutdown()

    barrel.closed = true

proc isClosed*(barrel: Barrel): bool =
  ## Check if the barrel is closed
  barrel.closed

# Note: Auto-compaction for single file mode requires different implementation
# The current compact system expects multiple files to merge
# For now, compaction is configured but not fully functional

# Helper to get entry from index (mode-independent)
proc indexGet(barrel: Barrel, key: string): Option[KeyDirEntry] =
  case barrel.mode
  of bmHash:
    barrel.keyDir.get(key)
  of bmCritBit:
    barrel.critBit.get(key)
  of bmHugeCritBit:
    # TODO: HugeBarrel lookup (Phase 3)
    raise newException(ValueError, "bmHugeCritBit not yet implemented")

# Helper to add entry to index (mode-independent)
proc indexAdd(barrel: Barrel, key: string, entry: KeyDirEntry) =
  case barrel.mode
  of bmHash:
    barrel.keyDir.add(key, entry)
  of bmCritBit:
    barrel.critBit.add(key, entry)
  of bmHugeCritBit:
    # TODO: HugeBarrel add (Phase 3)
    raise newException(ValueError, "bmHugeCritBit not yet implemented")

# Helper to get all keys from index
proc indexKeys(barrel: Barrel): seq[string] =
  case barrel.mode
  of bmHash:
    result = barrel.keyDir.keys()
  of bmCritBit:
    result = barrel.critBit.keys()
  of bmHugeCritBit:
    # TODO: HugeBarrel keys (Phase 3)
    raise newException(ValueError, "bmHugeCritBit not yet implemented")

# Helper to clear index
proc indexClear(barrel: Barrel) =
  case barrel.mode
  of bmHash:
    barrel.keyDir.clear()
  of bmCritBit:
    barrel.critBit.clear()
  of bmHugeCritBit:
    # TODO: HugeBarrel clear (Phase 3)
    raise newException(ValueError, "bmHugeCritBit not yet implemented")

# Helper to get index length
proc indexLen(barrel: Barrel): int =
  case barrel.mode
  of bmHash:
    barrel.keyDir.len()
  of bmCritBit:
    barrel.critBit.len()
  of bmHugeCritBit:
    # TODO: HugeBarrel len (Phase 3)
    raise newException(ValueError, "bmHugeCritBit not yet implemented")

proc set*(barrel: Barrel, key: string, value: string, ttl: int = -1): bool =
  ## Set a key-value pair with optional TTL
  ## ttl: TTL in seconds, -1 uses defaultTtl from config, 0 = no expiration
  if barrel.closed:
    return false

  let rawTimestamp = getTime().toUnix() * 1000  # Convert to milliseconds
  let ttlToUse = if ttl == -1: barrel.config.defaultTtl else: ttl

  try:
    let info = barrel.dataFile.appendRecord(key, value, rawTimestamp div 1000)
    let entry = KeyDirEntry(
      fileId: barrel.fileId,
      recordPos: info.recordPos,
      valuePos: info.valuePos,
      valueSize: info.valueSize,
      timestamp: encodeTimestamp(rawTimestamp, ttlToUse),
      recordSize: info.recordSize,
      deleted: false  # Not a tombstone
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

    # Fast path: check deleted flag before disk read
    if entry.deleted:
      return ""

    let recordInfo = RecordInfo(
      recordPos: entry.recordPos,
      valuePos: entry.valuePos,
      valueSize: entry.valueSize,
      recordSize: entry.recordSize
    )
    try:
      let (_, value, _) = barrel.dataFile.readRecord(recordInfo)

      # Check expiration if enabled
      if barrel.config.checkExpirationOnRead and isExpired(entry.timestamp):
        if barrel.config.deleteExpiredOnRead:
          # Write tombstone (handled by external call)
          # We can't call barrel.delete(key) here due to recursion
          # Instead, we'll let the caller handle it
          return ""
        return ""

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
      recordSize: info.recordSize,
      deleted: true  # Mark as deleted
    )
    barrel.indexAdd(key, entry)
    return true
  except:
    return false

proc exists*(barrel: Barrel, key: string): bool =
  ## Check if a key exists (and is not deleted)
  ## Now O(1) - no disk read needed thanks to deleted flag
  if barrel.closed:
    return false

  let found = barrel.indexGet(key)
  if found.isSome():
    return not found.get().deleted
  return false

proc count*(barrel: Barrel): int =
  ## Get number of non-deleted keys in store
  ## Uses deleted flag for O(n) in-memory counting (no disk reads)
  if barrel.closed:
    return 0

  case barrel.mode
  of bmHash:
    var count = 0
    for key, entry in barrel.keyDir.pairs():
      if not entry.deleted:
        inc count
    return count
  of bmCritBit:
    var count = 0
    for key, entry in barrel.critBit.pairs():
      if not entry.deleted:
        inc count
    return count
  of bmHugeCritBit:
    # TODO: HugeBarrel count (Phase 3)
    raise newException(ValueError, "bmHugeCritBit not yet implemented")

proc listKeys*(barrel: Barrel, limit: int = 1000, offset: int = 0): seq[string] =
  ## List non-deleted keys with pagination to avoid OOM
  ## limit: Maximum number of keys to return (default: 1000)
  ## offset: Number of keys to skip (default: 0)
  result = @[]
  if barrel.closed:
    return

  var skipped = 0
  var collected = 0

  case barrel.mode
  of bmHash:
    for key, entry in barrel.keyDir.pairs():
      if entry.deleted:
        continue
      if skipped < offset:
        inc skipped
        continue
      if collected >= limit:
        break
      result.add(key)
      inc collected
  of bmCritBit:
    for key, entry in barrel.critBit.pairs():
      if entry.deleted:
        continue
      if skipped < offset:
        inc skipped
        continue
      if collected >= limit:
        break
      result.add(key)
      inc collected
  of bmHugeCritBit:
    # TODO: HugeBarrel listKeys (Phase 3)
    raise newException(ValueError, "bmHugeCritBit not yet implemented")

proc clear*(barrel: Barrel): bool =
  ## Clear all keys (values remain in file but won't be accessible)
  if barrel.closed:
    return false

  try:
    barrel.indexClear()
    return true
  except:
    return false

# TTL-specific operations

proc setTtl*(barrel: Barrel, key: string, ttlSeconds: int): bool =
  ## Set TTL for an existing key (rewrites the record)
  ## Returns true if key existed and TTL was set
  if barrel.closed:
    return false

  # First get the current value
  let currentValue = barrel.get(key)
  if currentValue.len == 0:
    return false  # Key doesn't exist

  # Rewrite with new TTL
  result = barrel.set(key, currentValue, ttlSeconds)

proc getTtl*(barrel: Barrel, key: string): int =
  ## Get remaining TTL for a key in seconds
  ## Returns 0 if key doesn't exist or has no expiration
  if barrel.closed:
    return 0

  let found = barrel.indexGet(key)
  if found.isSome():
    let entry = found.get()
    result = getRemainingTtl(entry.timestamp)
  else:
    result = 0

# CritBit mode specific operations (range queries)

proc keysWithPrefix*(barrel: Barrel, prefix: string, limit: int = 1000, offset: int = 0): seq[string] =
  ## Get keys that start with the given prefix with pagination
  ## limit: Maximum number of keys to return (default: 1000)
  ## offset: Number of keys to skip (default: 0)
  if barrel.closed:
    return @[]

  var skipped = 0
  var collected = 0
  result = @[]

  case barrel.mode
  of bmCritBit:
    # CritBit has efficient prefix search, but still apply pagination
    for key, entry in barrel.critBit.pairsWithPrefix(prefix):
      if entry.deleted:
        continue
      if skipped < offset:
        inc skipped
        continue
      if collected >= limit:
        break
      result.add(key)
      inc collected
  of bmHash:
    for key, entry in barrel.keyDir.pairs():
      if entry.deleted:
        continue
      if key.len >= prefix.len and key[0..<prefix.len] == prefix:
        if skipped < offset:
          inc skipped
          continue
        if collected >= limit:
          break
        result.add(key)
        inc collected
  of bmHugeCritBit:
    # TODO: HugeBarrel keysWithPrefix (Phase 3)
    raise newException(ValueError, "bmHugeCritBit not yet implemented")

proc keysInRange*(barrel: Barrel, startKey: string, endKey: string, limit: int = 1000, offset: int = 0): seq[string] =
  ## Get keys in the range [startKey, endKey) with pagination
  ## limit: Maximum number of keys to return (default: 1000)
  ## offset: Number of keys to skip (default: 0)
  if barrel.closed:
    return @[]

  var skipped = 0
  var collected = 0
  result = @[]

  case barrel.mode
  of bmCritBit:
    # CritBit doesn't have pairsInRange, use pairs with filtering
    for key, entry in barrel.critBit.pairs():
      if entry.deleted:
        continue
      if key >= startKey and key < endKey:
        if skipped < offset:
          inc skipped
          continue
        if collected >= limit:
          break
        result.add(key)
        inc collected
  of bmHash:
    for key, entry in barrel.keyDir.pairs():
      if entry.deleted:
        continue
      if key >= startKey and key < endKey:
        if skipped < offset:
          inc skipped
          continue
        if collected >= limit:
          break
        result.add(key)
        inc collected
  of bmHugeCritBit:
    # TODO: HugeBarrel keysInRange (Phase 3)
    raise newException(ValueError, "bmHugeCritBit not yet implemented")

proc countWithPrefix*(barrel: Barrel, prefix: string): int =
  ## Count non-deleted keys with given prefix
  if barrel.closed:
    return 0

  case barrel.mode
  of bmCritBit:
    result = 0
    for key, entry in barrel.critBit.pairsWithPrefix(prefix):
      if not entry.deleted:
        inc result
  of bmHash:
    result = 0
    for key, entry in barrel.keyDir.pairs():
      if not entry.deleted and key.len >= prefix.len and key[0..<prefix.len] == prefix:
        inc result
  of bmHugeCritBit:
    # TODO: HugeBarrel countWithPrefix (Phase 3)
    raise newException(ValueError, "bmHugeCritBit not yet implemented")

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


# Compaction operations

proc triggerCompact*(barrel: var Barrel): bool =
  ## Trigger manual compaction of the current data file
  ## Returns true if compaction was successful
  if barrel.closed or barrel.compactController == nil:
    return false

  case barrel.mode
  of bmHash, bmCritBit:
    # Build file path
    let dataPath = barrel.path
    let success = barrel.compactController.performCompact(dataPath, barrel.fileId)

    # If successful, the old file is deleted and we need to reopen the new file
    if success:
      # Close old data file
      barrel.dataFile.close()

      # Update file ID to the new compacted file
      barrel.fileId = barrel.fileId + 1

      # Convert UserSyncMode to storage SyncMode
      var storageSyncMode = syncImmediate
      case barrel.config.syncMode
      of UserSyncMode.None:
        storageSyncMode = syncBuffered
      of UserSyncMode.Sync:
        storageSyncMode = syncImmediate
      of UserSyncMode.Fsync:
        storageSyncMode = syncImmediate

      # Reopen the new data file
      let newPath = dataPath.replace(&"{barrel.fileId - 1:06d}.data", &"{barrel.fileId:06d}.data")
      barrel.dataFile = open(newPath, barrel.fileId, storageSyncMode,
                           shouldFsync = (barrel.config.syncMode == UserSyncMode.Fsync),
                           bufferSize = barrel.config.writeBufferSize,
                           validateCrc = barrel.config.validateCrc)

    return success
  of bmHugeCritBit:
    # TODO: HugeBarrel compaction (Phase 5)
    raise newException(ValueError, "bmHugeCritBit not yet implemented")

proc getCompactStats*(barrel: Barrel): CompactStats =
  ## Get statistics about the last compaction operation
  if barrel.compactController == nil:
    return CompactStats(
      recordsScanned: 0,
      recordsKept: 0,
      recordsDropped: 0,
      bytesScanned: 0,
      bytesWritten: 0,
      timeStarted: getTime(),
      timeCompleted: getTime()
    )
  barrel.compactController.getCompactStats()

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
