## BitBarrel High-Level API
##
## Provides a unified interface for key-value storage operations
## with support for multiple index modes: Hash, CritBit (ordered), and HugeCritBit (massive datasets)
##
## **Index Mode Selection:**
## - `bmHash` (default): O(1) lookups, fastest for simple get/set, no ordering
## - `bmCritBit`: O(k) lookups where k=key length, keys sorted, supports range/prefix queries
## - `bmHugeCritBit`: Two-tier architecture for massive datasets with range queries

import std/[times, options, os, strformat, strutils, endians, tables, typedthreads, sequtils]
import types
import config_yaml
import ../storage
import ../storage/datafile
import ../storage/keydir
import ../storage/critbitindex
import ../storage/record
import ../storage/compact
import ../storage/crc32
import ../storage/hintfile
import ../network/protocol
import ../pubsub/barrel_hooks
import ../pubsub/pubsub as pubsub_types

export types, datafile, protocol

type
  # Forward declaration for compaction thread args (used in thread pointer)
  CompactThreadArgs* = object
    barrelPtr*: pointer
    oldPath*: string
    oldFileId*: uint32
    newFileId*: uint32
    compactionStart*: int64

  BarrelObj {.acyclic.} = object
    ## Note: Marked {.acyclic.} to prevent ORC cycle detection crashes
    ## when using threaded compaction. CompactController also marked acyclic.
    path*: string
    dataFile: DataFile
    dataFiles: Table[uint32, DataFile]  # All open files by ID (for multi-file compaction)
    fileId: uint32
    config*: BarrelConfig
    closed: bool
    mode: BarrelMode
    # Mode-specific indexes
    keyDir: KeyDir              # Used for bmHash
    critBit: CritBitIndex       # Used for bmCritBit
    # TODO: hugeBarrel for bmHugeCritBit (Phase 3)
    # Compaction
    compactController*: CompactController  # Background compaction worker
    compactionState*: CompactionState      # State during non-blocking compaction
    compactionThreadPtr: pointer           # Pointer to compaction thread (for joining)

  Barrel* = ref BarrelObj

proc `=destroy`*(barrel: var BarrelObj) =
  ## Destructor for Barrel - break circular reference to help ORC
  if barrel.compactController != nil:
    barrel.compactController = nil

proc defaultBarrelConfig*(): BarrelConfig =
  ## Returns default configuration for Barrel
  result = BarrelConfig(
    writeBufferSize: 64 * 1024,  # 64KB
    syncMode: UserSyncMode.Sync,
    autoCompact: false,  # Disabled by default due to ORC GC issues with thread cleanup
    compactThreshold: 0.3,
    compactInterval: 60,        # Check every 60 seconds
    validateCrc: true,  # Validate CRC32 on reads (see docs/CRC.md)
    compressionConfig: nil,  # Use default compression (LZ4)
    defaultTtl: 0,              # No expiration by default
    checkExpirationOnRead: true,  # Check and ignore expired records
    deleteExpiredOnRead: false,  # Don't automatically write tombstones
    mode: bmHash,               # Default to hash mode
    hugeConfig: HugeBarrelConfig(
      maxEntriesPerRange: 100_000,
      rangeCacheSize: 10,
      maxDataFileSizeMB: 1024,
      autoSplitEnabled: true,
      flushIntervalMs: 0,
      enableBarrel2Recovery: true
    )
  )

proc rebuildIndexFromDataFile*(barrel: Barrel, validateCrc: bool = true): int =
  ## Rebuild the in-memory index from data file
  ## Uses hint files for fast recovery when available, falls back to full scan
  ## Returns number of records recovered
  ## This is called automatically when opening an existing barrel

  let filePath = barrel.path
  let fileSize = getFileSize(filePath)

  if fileSize <= HEADER_SIZE:
    return 0  # Empty or header-only file

  # Try hint file first (much faster than full scan)
  let hintPath = getHintPath(filePath)
  if hintFileExists(filePath):
    # Try to load from hint file
    var loaded = 0

    # Load from hint file into the appropriate index
    case barrel.mode
    of bmHash:
      loaded = loadKeyDirFromHint(hintPath, barrel.keyDir)
    of bmCritBit:
      # Hint files work with KeyDirEntry, so we need to read and add to CritBitIndex
      var tempKeyDir: KeyDir
      loaded = loadKeyDirFromHint(hintPath, tempKeyDir)
      if loaded > 0:
        # Transfer entries from KeyDir to CritBitIndex
        for key, entry in tempKeyDir.pairs():
          barrel.critBit.add(key, entry)
    of bmHugeCritBit:
      discard  # Not used for HugeBarrel

    if loaded > 0:
      echo fmt"Fast recovery: Loaded {loaded} records from hint file"
      return loaded
    else:
      echo fmt"Hint file invalid or corrupted, falling back to full scan"

  # Fall back to full scan
  var recordCount = 0
  var offset = HEADER_SIZE.int64

  let file = open(filePath, fmRead)
  defer: file.close()

  while offset < fileSize:
    file.setFilePos(offset, fspSet)

    # Read CRC32 (4 bytes)
    var storedCrc: uint32
    if file.readBuffer(addr storedCrc, 4) != 4:
      break

    # Read timestamp (8 bytes)
    var rawTimestamp: int64
    if file.readBuffer(addr rawTimestamp, 8) != 8:
      break
    var timestamp: int64
    littleEndian64(addr timestamp, addr rawTimestamp)

    # Read key length (4 bytes)
    var rawKeyLen: uint32
    if file.readBuffer(addr rawKeyLen, 4) != 4:
      break
    var keyLen: uint32
    littleEndian32(addr keyLen, addr rawKeyLen)

    # Validate key length
    if keyLen > types.MAX_KEY_SIZE.uint32 or keyLen == 0:
      break

    # Read key
    var key = newString(keyLen.int)
    if file.readBuffer(addr key[0], keyLen.int) != keyLen.int:
      break

    # Read value length (4 bytes)
    var rawValueLen: uint32
    if file.readBuffer(addr rawValueLen, 4) != 4:
      break
    var valueLen: uint32
    littleEndian32(addr valueLen, addr rawValueLen)

    # Validate value length
    if valueLen > types.MAX_VALUE_SIZE.uint32:
      break

    # Read flags (1 byte) and algorithm (1 byte) to detect compression
    var flags: uint8
    if file.readBuffer(addr flags, 1) != 1:
      break
    var algoId: uint8
    if file.readBuffer(addr algoId, 1) != 1:
      break

    # Check if value is compressed
    const COMPRESS_FLAG = 0b00000001
    let isCompressed = (flags and COMPRESS_FLAG) != 0

    # Read original length if compressed (NEW in Option 2 format)
    var originalLen: uint32 = 0
    if isCompressed:
      var rawOrigLen: uint32
      if file.readBuffer(addr rawOrigLen, 4) != 4:
        break
      littleEndian32(addr originalLen, addr rawOrigLen)

    # Calculate record size using NEW format
    # valueLen now stores ACTUAL size on disk (compressed or uncompressed)
    # originalLen (4 bytes) is only present when compressed
    let originalLenSize = if isCompressed: 4 else: 0
    let recordSize = (4 + 8 + 4 + keyLen.int + 4 + 1 + 1 + originalLenSize + valueLen.int).uint32

    # Validate CRC if enabled
    if validateCrc:
      let recordDataLen = recordSize.int - 4  # Exclude CRC
      file.setFilePos(offset + 4, fspSet)  # Position after CRC
      var recordData = newString(recordDataLen)
      if file.readBuffer(addr recordData[0], recordDataLen) != recordDataLen:
        break
      let computedCrc = crc32(recordData)
      if storedCrc != computedCrc:
        # CRC mismatch - try to continue from next byte
        offset += 1
        continue

    # Build KeyDirEntry
    let recordPos = offset.uint64 + 4  # Position after CRC

    # valueSize should be the uncompressed size for stats/reporting
    let entryValueSize = if isCompressed: originalLen else: valueLen

    let entry = KeyDirEntry(
      recordPos: recordPos,
      fileId: barrel.fileId,
      valueSize: entryValueSize,
      recordSize: recordSize,
      keyLen: keyLen.uint16
    )

    # Add to index (newer entries overwrite older)
    case barrel.mode
    of bmHash:
      barrel.keyDir.add(key, entry)
    of bmCritBit:
      barrel.critBit.add(key, entry)
    of bmHugeCritBit:
      discard  # Not used for HugeBarrel

    inc recordCount
    offset += recordSize.int64

  return recordCount

proc openBarrel*(path: string, fileId: uint32 = 1'u32, config: BarrelConfig = defaultBarrelConfig()): Barrel =
  ## Open a barrel with optional configuration
  ##
  ## If a persisted configuration file exists (e.g., "mydata.yaml" for "mydata.data"),
  ## it takes precedence over the provided config.
  ##
  ## **Example:**
  ## ```nim
  ## import bitbarrel
  ##
  ## # Open with default settings (bmHash mode)
  ## let barrel = openBarrel("mydata.db")
  ##
  ## # Open with ordered index for range queries
  ## var config = defaultBarrelConfig()
  ## config.mode = bmCritBit
  ## let orderedBarrel = openBarrel("data.db", config)
  ##
  ## # Use the barrel...
  ## barrel.close()
  ## ```
  result = Barrel()
  result.path = path
  result.fileId = fileId

  # Load persisted config if it exists, otherwise use provided config
  let persistedConfig = loadBarrelConfigYaml(path)
  let effectiveConfig = if persistedConfig.isSome(): persistedConfig.get() else: config

  result.config = effectiveConfig
  result.mode = effectiveConfig.mode
  result.closed = false
  result.dataFiles = initTable[uint32, DataFile]()
  result.compactionState = CompactionState(inProgress: false)

  # Convert UserSyncMode to storage SyncMode
  var storageSyncMode = syncImmediate
  case effectiveConfig.syncMode
  of UserSyncMode.None:
    storageSyncMode = syncBuffered
  of UserSyncMode.Sync:
    storageSyncMode = syncImmediate
  of UserSyncMode.Fsync:
    storageSyncMode = syncImmediate

  result.dataFile = open(path, fileId, storageSyncMode,
                         shouldFsync = (effectiveConfig.syncMode == UserSyncMode.Fsync),
                         bufferSize = effectiveConfig.writeBufferSize,
                         validateCrc = effectiveConfig.validateCrc,
                         compressionConfig = effectiveConfig.compressionConfig)
  result.dataFiles[fileId] = result.dataFile

  # Initialize index based on mode
  case effectiveConfig.mode
  of bmHash:
    result.keyDir = keydir.init()
  of bmCritBit:
    result.critBit = critbitindex.init()
  of bmHugeCritBit:
    # HugeBarrel uses a different architecture and API
    # Use storage/hugebarrel.openHugeBarrel() instead of openBarrel()
    raise newException(ValueError,
      "bmHugeCritBit mode requires using openHugeBarrel() from storage/hugebarrel module. " &
      "Example: import storage/hugebarrel; let hb = openHugeBarrel(path, config)")

  # Rebuild index from data file (for existing barrels)
  let recoveredCount = rebuildIndexFromDataFile(result, effectiveConfig.validateCrc)
  if recoveredCount > 0:
    echo fmt("Recovered {recoveredCount} records from data file")

  # Initialize compaction
  # Always create compactController for manual compaction, but only start
  # the background worker if autoCompact is explicitly enabled
  var compactConfig: CompactConfig
  compactConfig.enabled = effectiveConfig.autoCompact  # Background worker only when explicitly enabled
  compactConfig.maxFileSize = 1024 * 1024 * 1024  # 1GB default
  compactConfig.triggerThreshold = effectiveConfig.compactThreshold
  compactConfig.compactInterval = effectiveConfig.compactInterval
  compactConfig.compactIntervalBytes = 10 * 1024 * 1024  # 10MB

  # Initialize with appropriate index based on mode
  # Note: We don't pass a callback because the non-blocking compaction path
  # (used by triggerCompact) handles all state updates in compactWorkerThread.
  # This avoids ORC issues with proc references.
  case effectiveConfig.mode
  of bmHash:
    result.compactController = newCompactController(compactConfig, addr(result.keyDir))
  of bmCritBit:
    result.compactController = newCompactController(compactConfig, addr(result.critBit))
  of bmHugeCritBit:
    # TODO: HugeBarrel compaction (Phase 5)
    result.compactController = nil

  # Set barrel path for compaction
  if result.compactController != nil:
    let dataDir = if parentDir(path) == "": "." else: parentDir(path)
    result.compactController.setBarrelPath(dataDir)

    # Start background worker only if autoCompact is enabled
    if result.compactController.config.enabled:
      result.compactController.startCompactWorker()

proc openBarrel*(path: string, config: BarrelConfig): Barrel =
  ## Open a barrel with configuration (no fileId needed)
  openBarrel(path, 1'u32, config)

proc joinCompactionThread(barrel: Barrel) =
  ## Join the compaction thread if one is running
  ## Note: Thread is allocated with create() and manually freed
  if barrel.compactionThreadPtr != nil:
    # Cast back to the correct type and join
    let threadPtr = cast[ptr Thread[CompactThreadArgs]](barrel.compactionThreadPtr)
    threadPtr[].joinThread()
    # Note: Do NOT dealloc here - let the GC handle it to avoid heap corruption
    # Setting to nil allows GC to collect the CompactThreadArgs
    barrel.compactionThreadPtr = nil

proc close*(barrel: Barrel) =
  ## Close the barrel
  if not barrel.closed:
    # Wait for any in-progress compaction to complete before closing
    while barrel.compactionState.inProgress:
      sleep(10)

    # Join the compaction thread to ensure clean shutdown
    barrel.joinCompactionThread()

    # IMPORTANT: Shutdown compactController BEFORE deinitializing keyDir/critBit
    # The controller's closures capture pointers to these structures
    if barrel.compactController != nil:
      barrel.compactController.shutdown()
      barrel.compactController = nil

    barrel.dataFile.close()

    # Close any additional open files
    for fileId in toSeq(barrel.dataFiles.keys):
      if fileId != barrel.fileId:  # Don't double-close the main file
        barrel.dataFiles[fileId].close()
    barrel.dataFiles.clear()

    case barrel.mode
    of bmHash:
      barrel.keyDir.deinit()
    of bmCritBit:
      barrel.critBit.deinit()
    of bmHugeCritBit:
      # TODO: Close HugeBarrel (Phase 3)
      discard

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
proc indexAdd(barrel: Barrel, key: string, entry: KeyDirEntry): bool =
  case barrel.mode
  of bmHash:
    barrel.keyDir.add(key, entry)
    return true
  of bmCritBit:
    barrel.critBit.add(key, entry)
    return true
  of bmHugeCritBit:
    # TODO: HugeBarrel add (Phase 3)
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
  ##
  ## ttl: TTL in seconds, -1 uses defaultTtl from config, 0 = no expiration
  ##
  ## **Example:**
  ## ```nim
  ## let barrel = openBarrel("mydata.db")
  ##
  ## # Basic set
  ## barrel.set("user:1", "Alice")
  ##
  ## # Set with TTL (expires in 1 hour)
  ## barrel.set("session:xyz", "data", ttl=3600)
  ##
  ## # Set with default TTL from config
  ## barrel.set("cache:key", "value")  # Uses ttl=-1 (default)
  ##
  ## barrel.close()
  ## ```
  if barrel.closed:
    return false

  let nowTsMs = getTime().toUnix() * 1000  # Convert to milliseconds
  # Use configured TTL if not specified (-1), or explicit TTL
  let ttlToUse = if ttl == -1: barrel.config.defaultTtl else: ttl
  # Encode timestamp with TTL
  let encodedTimestamp = encodeTimestamp(nowTsMs, ttlToUse)

  try:
    # Route writes to new file during compaction
    let targetFileId = if barrel.compactionState.inProgress:
      barrel.compactionState.newFileId
    else:
      barrel.fileId

    let info = if barrel.compactionState.inProgress:
      barrel.dataFiles[barrel.compactionState.newFileId].appendRecord(key, value, encodedTimestamp)
    else:
      barrel.dataFile.appendRecord(key, value, encodedTimestamp)

    let entry = KeyDirEntry(
      recordPos: info.recordPos,
      fileId: targetFileId,
      valueSize: info.valueSize,
      recordSize: info.recordSize,
      keyLen: info.keyLen
    )
    if barrel.indexAdd(key, entry):
      # Trigger pub/sub k/v change event
      triggerBarrelHooks(barrel.path, key, pubsub_types.kvSet, value)
      return true
    return false
  except:
    return false

proc get*(barrel: Barrel, key: string): string =
  ## Get a value by key (returns empty string if not found)
  ##
  ## **Example:**
  ## ```nim
  ## let barrel = openBarrel("mydata.db")
  ##
  ## barrel.set("user:1", "Alice")
  ##
  ## # Get value
  ## let value = barrel.get("user:1")  # Returns "Alice"
  ##
  ## # Handle missing key
  ## let missing = barrel.get("user:999")  # Returns ""
  ## if missing.len == 0:
  ##   echo "Key not found"
  ##
  ## barrel.close()
  ## ```
  if barrel.closed:
    return ""

  let found = barrel.indexGet(key)
  if found.isSome():
    let entry = found.get()

    # Fast path: check deleted flag before disk read
    if entry.isDeleted:
      return ""

    let recordInfo = RecordInfo(
      recordPos: entry.recordPos,
      valueSize: entry.valueSize,
      recordSize: entry.recordSize,
      keyLen: entry.keyLen
    )
    try:
      # Select the correct data file based on entry's fileId
      var value: string
      var timestamp: int64 = 0
      if barrel.dataFiles.hasKey(entry.fileId):
        var df = barrel.dataFiles[entry.fileId]
        let (_, v, ts) = df.readRecord(recordInfo)
        value = v
        timestamp = ts
      else:
        let (_, v, ts) = barrel.dataFile.readRecord(recordInfo)
        value = v
        timestamp = ts

      # Check expiration if enabled (timestamp read from disk)
      if barrel.config.checkExpirationOnRead and isExpired(timestamp):
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
  ##
  ## **Note:** Deletion is implemented by writing a tombstone record
  ## (empty value). The key remains in the data file but is marked as deleted.
  ##
  ## **Example:**
  ## ```nim
  ## let barrel = openBarrel("mydata.db")
  ##
  ## barrel.set("user:1", "Alice")
  ## barrel.delete("user:1")
  ##
  ## # Key no longer exists
  ## let value = barrel.get("user:1")  # Returns ""
  ## echo barrel.exists("user:1")  # Returns false
  ##
  ## barrel.close()
  ## ```
  if barrel.closed:
    return false

  let timestamp = getTime().toUnix()
  try:
    # Route writes to new file during compaction
    let targetFileId = if barrel.compactionState.inProgress:
      barrel.compactionState.newFileId
    else:
      barrel.fileId

    # Write empty value as tombstone
    let info = if barrel.compactionState.inProgress:
      barrel.dataFiles[barrel.compactionState.newFileId].appendRecord(key, "", timestamp)
    else:
      barrel.dataFile.appendRecord(key, "", timestamp)

    let entry = KeyDirEntry(
      recordPos: info.recordPos,
      fileId: targetFileId,
      valueSize: 0,  # Empty value = tombstone
      recordSize: info.recordSize,
      keyLen: info.keyLen
    )
    if barrel.indexAdd(key, entry):
      # Trigger pub/sub k/v change event
      triggerBarrelHooks(barrel.path, key, pubsub_types.kvDelete, "")
      return true
    return false
  except:
    return false

proc exists*(barrel: Barrel, key: string): bool =
  ## Check if a key exists (and is not deleted)
  ## O(1) - valueSize == 0 indicates tombstone
  if barrel.closed:
    return false

  let found = barrel.indexGet(key)
  if found.isSome():
    return not found.get().isDeleted
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
      if not entry.isDeleted:
        inc count
    return count
  of bmCritBit:
    var count = 0
    for key, entry in barrel.critBit.pairs():
      if not entry.isDeleted:
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
      if entry.isDeleted:
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
      if entry.isDeleted:
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
  ##
  ## Returns true if key existed and TTL was set
  ##
  ## **Example:**
  ## ```nim
  ## let barrel = openBarrel("mydata.db")
  ##
  ## barrel.set("session:abc", "user data")
  ##
  ## # Set TTL after creation
  ## barrel.setTtl("session:abc", 1800)  # Expires in 30 minutes
  ##
  ## # Check remaining TTL
  ## let remaining = barrel.getTtl("session:abc")
  ##
  ## barrel.close()
  ## ```
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
  ## Note: Requires disk read since timestamp not stored in index
  if barrel.closed:
    return 0

  let found = barrel.indexGet(key)
  if found.isSome():
    let entry = found.get()
    if entry.isDeleted:
      return 0
    # Read timestamp from disk
    let recordInfo = RecordInfo(
      recordPos: entry.recordPos,
      valueSize: entry.valueSize,
      recordSize: entry.recordSize,
      keyLen: entry.keyLen
    )
    try:
      var timestamp: int64 = 0
      if barrel.dataFiles.hasKey(entry.fileId):
        var df = barrel.dataFiles[entry.fileId]
        let (_, _, ts) = df.readRecord(recordInfo)
        timestamp = ts
      else:
        let (_, _, ts) = barrel.dataFile.readRecord(recordInfo)
        timestamp = ts
      result = getRemainingTtl(timestamp)
    except:
      result = 0
  else:
    result = 0

# CritBit mode specific operations (range queries)

proc keysWithPrefixOffset*(barrel: Barrel, prefix: string, limit: int = 1000, offset: int = 0): seq[string] =
  ## Get keys that start with the given prefix with offset-based pagination (deprecated)
  ## limit: Maximum number of keys to return (default: 1000)
  ## offset: Number of keys to skip (default: 0)
  ##
  ## **Deprecated:** Use keysWithPrefix with cursor-based pagination instead
  if barrel.closed:
    return @[]

  var skipped = 0
  var collected = 0
  result = @[]

  case barrel.mode
  of bmCritBit:
    # CritBit has efficient prefix search, but still apply pagination
    for key, entry in barrel.critBit.pairsWithPrefix(prefix):
      if entry.isDeleted:
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
      if entry.isDeleted:
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

proc keysWithPrefix*(barrel: Barrel, prefix: string,
                    limit: int = 1000, cursor: string = ""): (seq[string], string, bool) =
  ## Get keys with prefix with cursor-based pagination
  ##
  ## Only available in bmCritBit mode
  ## limit: Maximum number of keys to return (default: 1000)
  ## cursor: Last key from previous page (empty string for first page)
  ## Returns: ``(keys: seq[string], nextCursor: string, hasMore: bool)``
  ##
  ## **Example:**
  ## ```nim
  ## var config = defaultBarrelConfig()
  ## config.mode = bmCritBit
  ## let barrel = openBarrel("data.db", config)
  ##
  ## # Add user data
  ## barrel.set("user:100", "Alice")
  ## barrel.set("user:200", "Bob")
  ## barrel.set("user:300", "Charlie")
  ##
  ## # Paginate through all user keys
  ## var cursor = ""
  ## var allKeys: seq[string]
  ##
  ## while true:
  ##   let (keys, nextCursor, hasMore) = barrel.keysWithPrefix("user:", 100, cursor)
  ##   allKeys.add(keys)
  ##   if not hasMore:
  ##     break
  ##   cursor = nextCursor
  ## ```
  if barrel.closed:
    return (@[], "", false)

  case barrel.mode
  of bmCritBit:
    # Use the CritBit index's cursor-based API
    result = barrel.critBit.keysWithPrefix(prefix, limit, cursor)
  of bmHash:
    # Hash mode doesn't support ordered prefix queries
    raise newException(ValueError, "keysWithPrefix requires bmCritBit mode")
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
      if entry.isDeleted:
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
      if entry.isDeleted:
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

proc keysInRange*(barrel: Barrel, startKey: string, endKey: string,
                  limit: int = 1000, cursor: string = ""): (seq[string], string, bool) =
  ## Get keys in the range [startKey, endKey) with cursor-based pagination
  ##
  ## Only available in bmCritBit mode
  ## limit: Maximum number of keys to return (default: 1000)
  ## cursor: Last key from previous page (empty string for first page)
  ## Returns: ``(keys: seq[string], nextCursor: string, hasMore: bool)``
  ##
  ## **Example:**
  ## ```nim
  ## var config = defaultBarrelConfig()
  ## config.mode = bmCritBit
  ## let barrel = openBarrel("data.db", config)
  ##
  ## # Add sorted data
  ## for i in 0..<1000:
  ##   barrel.set(fmt"user:{i:04d}", "data")
  ##
  ## # Paginate through range
  ## var cursor = ""
  ## var allKeys: seq[string]
  ##
  ## while true:
  ##   let (keys, nextCursor, hasMore) = barrel.keysInRange("user:0000", "user:1000", 100, cursor)
  ##   allKeys.add(keys)
  ##   if not hasMore:
  ##     break
  ##   cursor = nextCursor
  ## ```
  if barrel.closed:
    return (@[], "", false)

  case barrel.mode
  of bmCritBit:
    # Use the CritBit index's cursor-based API
    result = barrel.critBit.keysInRange(startKey, endKey, limit, cursor)
  of bmHash:
    # Hash mode doesn't support ordered range queries
    raise newException(ValueError, "keysInRange requires bmCritBit mode")
  of bmHugeCritBit:
    # TODO: HugeBarrel keysInRange (Phase 3)
    raise newException(ValueError, "bmHugeCritBit not yet implemented")

iterator keys*(barrel: Barrel): string =
  ## Iterate over all non-deleted keys in the barrel
  if not barrel.closed:
    case barrel.mode
    of bmCritBit:
      for key, entry in barrel.critBit.pairs():
        if not entry.isDeleted:
          yield key
    of bmHash:
      for key, entry in barrel.keyDir.pairs():
        if not entry.isDeleted:
          yield key
    of bmHugeCritBit:
      # TODO: HugeBarrel keys (Phase 3)
      raise newException(ValueError, "bmHugeCritBit not yet implemented")

proc countWithPrefix*(barrel: Barrel, prefix: string): int =
  ## Count non-deleted keys with given prefix
  if barrel.closed:
    return 0

  case barrel.mode
  of bmCritBit:
    result = 0
    for key, entry in barrel.critBit.pairsWithPrefix(prefix):
      if not entry.isDeleted:
        inc result
  of bmHash:
    result = 0
    for key, entry in barrel.keyDir.pairs():
      if not entry.isDeleted and key.len >= prefix.len and key[0..<prefix.len] == prefix:
        inc result
  of bmHugeCritBit:
    # TODO: HugeBarrel countWithPrefix (Phase 3)
    raise newException(ValueError, "bmHugeCritBit not yet implemented")

# Range query methods with values and cursor-based pagination
# Only available in bmCritBit mode

proc itemsInRange*(barrel: Barrel, startKey: string, endKey: string, limit: int = 1000, cursor: string = ""): (seq[(string, string)], string, bool) =
  ## Get key-value pairs in range [startKey, endKey) with cursor-based pagination
  ##
  ## Only available in bmCritBit mode
  ## limit: Maximum number of items to return (default: 1000)
  ## cursor: Last key from previous page (empty string for first page)
  ## Returns: ``(items: seq[(string, string)], nextCursor: string, hasMore: bool)``
  ##
  ## **Example:**
  ## ```nim
  ## var config = defaultBarrelConfig()
  ## config.mode = bmCritBit
  ## let barrel = openBarrel("data.db", config)
  ##
  ## # Add some data
  ## barrel.set("user:100", "Alice")
  ## barrel.set("user:200", "Bob")
  ##
  ## # Get first page
  ## var cursor = ""
  ## let (items, nextCursor, hasMore) = barrel.itemsInRange("user:0", "user:999", 100, cursor)
  ##
  ## # Get next page if available
  ## if hasMore:
  ##   let (page2, nextCursor2, hasMore2) = barrel.itemsInRange("user:0", "user:999", 100, nextCursor)
  ##
  ## barrel.close()
  ## ```
  if barrel.closed:
    return (@[], "", false)

  if barrel.mode != bmCritBit:
    raise newException(ValueError, "Range queries with values require bmCritBit mode")

  var items: seq[(string, string)] = @[]
  var lastKey = ""

  # Get entries from CritBitIndex
  let entries = barrel.critBit.itemsInRange(startKey, endKey, limit, cursor)

  for entry in entries:
    let (key, dirEntry) = entry
    # Skip deleted entries
    if dirEntry.isDeleted:
      continue

    # Read value from DataFile
    let recordInfo = RecordInfo(
      recordPos: dirEntry.recordPos,
      valueSize: dirEntry.valueSize,
      recordSize: dirEntry.recordSize,
      keyLen: dirEntry.keyLen
    )

    try:
      let (_, value, timestamp) = barrel.dataFile.readRecord(recordInfo)

      # Check expiration if enabled (using timestamp from disk)
      if barrel.config.checkExpirationOnRead and isExpired(timestamp):
        continue

      items.add((key, value))
      lastKey = key
    except:
      # Skip entries that can't be read
      continue

  # Determine if there are more items
  # If we got exactly 'limit' items, there might be more
  let hasMore = items.len == limit

  result = (items, lastKey, hasMore)

proc itemsWithPrefix*(barrel: Barrel, prefix: string, limit: int = 1000, cursor: string = ""): (seq[(string, string)], string, bool) =
  ## Get key-value pairs with given prefix with cursor-based pagination
  ##
  ## Only available in bmCritBit mode
  ## limit: Maximum number of items to return (default: 1000)
  ## cursor: Last key from previous page (empty string for first page)
  ## Returns: ``(items: seq[(string, string)], nextCursor: string, hasMore: bool)``
  ##
  ## **Example:**
  ## ```nim
  ## var config = defaultBarrelConfig()
  ## config.mode = bmCritBit
  ## let barrel = openBarrel("data.db", config)
  ##
  ## # Add user data
  ## barrel.set("user:100", "Alice")
  ## barrel.set("user:200", "Bob")
  ## barrel.set("user:300", "Charlie")
  ##
  ## # Paginate through all users
  ## var cursor = ""
  ## var allUsers: seq[(string, string)]
  ##
  ## while true:
  ##   let (items, nextCursor, hasMore) = barrel.itemsWithPrefix("user:", 100, cursor)
  ##   if items.len == 0: break
  ##   allUsers.add(items)
  ##   if not hasMore: break
  ##   cursor = nextCursor
  ##
  ## # Print all users
  ## for (key, value) in allUsers:
  ##   echo key, " => ", value
  ##
  ## barrel.close()
  ## ```
  if barrel.closed:
    return (@[], "", false)

  if barrel.mode != bmCritBit:
    raise newException(ValueError, "Range queries with values require bmCritBit mode")

  var items: seq[(string, string)] = @[]
  var lastKey = ""

  # Get entries from CritBitIndex
  let entries = barrel.critBit.itemsWithPrefix(prefix, limit, cursor)

  for entry in entries:
    let (key, dirEntry) = entry
    # Skip deleted entries
    if dirEntry.isDeleted:
      continue

    # Read value from DataFile
    let recordInfo = RecordInfo(
      recordPos: dirEntry.recordPos,
      valueSize: dirEntry.valueSize,
      recordSize: dirEntry.recordSize,
      keyLen: dirEntry.keyLen
    )

    try:
      let (_, value, timestamp) = barrel.dataFile.readRecord(recordInfo)

      # Check expiration if enabled (using timestamp from disk)
      if barrel.config.checkExpirationOnRead and isExpired(timestamp):
        continue

      items.add((key, value))
      lastKey = key
    except:
      # Skip entries that can't be read
      continue

  # Determine if there are more items
  # If we got exactly 'limit' items, there might be more
  let hasMore = items.len == limit

  result = (items, lastKey, hasMore)

iterator itemsInRange*(barrel: Barrel, startKey: string, endKey: string): (string, string) =
  ## Iterate over key-value pairs in range [startKey, endKey)
  ## Only available in bmCritBit mode
  if not barrel.closed and barrel.mode == bmCritBit:
    for key, entry in barrel.critBit.itemsInRange(startKey, endKey):
      # Skip deleted entries
      if entry.isDeleted:
        continue

      # Read value from DataFile
      let recordInfo = RecordInfo(
        recordPos: entry.recordPos,
        valueSize: entry.valueSize,
        recordSize: entry.recordSize,
        keyLen: entry.keyLen
      )

      try:
        let (_, value, timestamp) = barrel.dataFile.readRecord(recordInfo)

        # Check expiration if enabled (using timestamp from disk)
        if barrel.config.checkExpirationOnRead and isExpired(timestamp):
          continue

        yield (key, value)
      except:
        # Skip entries that can't be read
        continue

iterator itemsWithPrefix*(barrel: Barrel, prefix: string): (string, string) =
  ## Iterate over key-value pairs with given prefix
  ## Only available in bmCritBit mode
  if not barrel.closed and barrel.mode == bmCritBit:
    for key, entry in barrel.critBit.itemsWithPrefix(prefix):
      # Skip deleted entries
      if entry.isDeleted:
        continue

      # Read value from DataFile
      let recordInfo = RecordInfo(
        recordPos: entry.recordPos,
        valueSize: entry.valueSize,
        recordSize: entry.recordSize,
        keyLen: entry.keyLen
      )

      try:
        let (_, value, timestamp) = barrel.dataFile.readRecord(recordInfo)

        # Check expiration if enabled (using timestamp from disk)
        if barrel.config.checkExpirationOnRead and isExpired(timestamp):
          continue

        yield (key, value)
      except:
        # Skip entries that can't be read
        continue

# Utility functions

proc getMode*(barrel: Barrel): BarrelMode =
  ## Get the index mode of the barrel
  barrel.mode

proc getConfig*(barrel: Barrel): BarrelConfig =
  ## Get the configuration of the barrel
  barrel.config

proc setConfig*(barrel: Barrel, config: BarrelConfig) =
  ## Update the barrel configuration and persist to disk
  ##
  ## Note: The `mode` field cannot be changed at runtime as it
  ## requires rebuilding the entire index structure. The server
  ## should validate this before calling setConfig.
  ##
  ## **Example:**
  ## ```nim
  ## var config = barrel.getConfig()
  ## config.autoCompact = true
  ## config.compactThreshold = 0.5
  ## barrel.setConfig(config)
  ## ```
  barrel.config = config
  saveBarrelConfigYaml(barrel.path, config)

proc getPath*(barrel: Barrel): string =
  ## Get the data file path
  barrel.path

proc deleteBarrel*(path: string): bool =
  ## Delete a barrel and all its associated files
  ##
  ## **Example:**
  ## ```nim
  ## # Create and use a barrel
  ## let barrel = openBarrel("temp.db")
  ## barrel.close()
  ##
  ## # Delete it
  ## let success = deleteBarrel("temp.db")
  ## ```
  ##
  ## This removes:
  ## - Data files (*.data)
  ## - Hint files (*.hint)
  ## - Other auxiliary files
  var deleted = true

  for ext in [".data", ".hint", ".compacted"]:
    let filePath = path & ext
    if fileExists(filePath):
      try:
        removeFile(filePath)
      except OSError:
        deleted = false

  return deleted

proc indexCount*(barrel: Barrel): int =
  ## Get the number of entries in the index (including tombstones)
  barrel.indexLen()

proc getStats*(barrel: Barrel): BarrelStats =
  ## Get comprehensive statistics for the barrel
  ##
  ## Returns detailed metrics about keys, storage, performance,
  ## compaction status, and configuration.
  ##
  ## **Example:**
  ## ```nim
  ## let stats = barrel.getStats()
  ## echo "Total keys: ", stats.totalKeys
  ## echo "Active keys: ", stats.activeKeys
  ## echo "Disk usage: ", formatSize(stats.totalSize)
  ## echo "Fragmentation: ", formatFloat(stats.fragmentationRatio * 100)
  ## ```
  ##
  ## This method calculates:
  ## - Key statistics (total, active, deleted)
  ## - Storage metrics (file sizes, disk usage)
  ## - Performance indicators (avg key/value sizes)
  ## - Compaction status and fragmentation ratio
  ## - Configuration details
  ## - Memory usage estimates
  result.dataPath = barrel.path

  # Get key directory statistics based on index mode
  case barrel.mode
  of bmHash:
    result.totalKeys = int64(barrel.keyDir.len())
    result.activeKeys = int64(barrel.keyDir.countActive())
    result.deletedKeys = int64(barrel.keyDir.countDeleted())

    # Calculate average sizes by iterating keydir
    var totalKeySize = 0
    var totalValueSize = 0
    for key, entry in barrel.keyDir.pairs():
      if not entry.isDeleted():
        totalKeySize += key.len
        totalValueSize += int(entry.valueSize)

    if result.activeKeys > 0:
      result.avgKeySize = totalKeySize.float / result.activeKeys.float
      result.avgValueSize = totalValueSize.float / result.activeKeys.float
      result.avgRecordSize = (totalKeySize + totalValueSize).float / result.activeKeys.float

  of bmCritBit:
    result.totalKeys = int64(barrel.critBit.len())
    result.activeKeys = int64(barrel.critBit.countActive())
    result.deletedKeys = int64(barrel.critBit.countDeleted())

    # Calculate average sizes by iterating critbit
    var totalKeySize = 0
    var totalValueSize = 0
    for key, entry in barrel.critBit.pairs():
      if not entry.isDeleted():
        totalKeySize += key.len
        totalValueSize += int(entry.valueSize)

    if result.activeKeys > 0:
      result.avgKeySize = totalKeySize.float / result.activeKeys.float
      result.avgValueSize = totalValueSize.float / result.activeKeys.float
      result.avgRecordSize = (totalKeySize + totalValueSize).float / result.activeKeys.float

  of bmHugeCritBit:
    result.totalKeys = 0  # TODO: Implement for HugeBarrel
    result.activeKeys = 0
    result.deletedKeys = 0

  # Get storage statistics
  if fileExists(barrel.path):
    result.activeFileSize = int64(getFileSize(barrel.path))

  # Calculate total directory size and file count
  let dataDir = parentDir(barrel.path)
  if dirExists(dataDir):
    var totalSize = 0'i64
    var fileCount = 0

    for ext in [".data", ".hint", ".compacted"]:
      let pattern = dataDir / "*" & ext
      for filePath in walkPattern(pattern):
        if fileExists(filePath):
          totalSize += int64(getFileSize(filePath))
          inc fileCount

    result.totalSize = totalSize
    result.fileCount = fileCount

  # Get compaction statistics if available
  if barrel.compactController != nil:
    let compactStats = barrel.compactController.getCompactStats()
    result.isCompacting = barrel.compactController.compactInProgress
    result.recordsScanned = int64(compactStats.recordsScanned)
    result.recordsKept = int64(compactStats.recordsKept)
    result.recordsDropped = int64(compactStats.recordsDropped)

    # Calculate fragmentation ratio from compaction stats
    if compactStats.recordsScanned > 0:
      result.fragmentationRatio = 1.0 - (float(compactStats.recordsKept) / float(compactStats.recordsScanned))

    # Get last compaction time
    if compactStats.timeStarted != Time():
      result.lastCompactTime = $compactStats.timeStarted
  else:
    result.isCompacting = false
    result.fragmentationRatio = 0.0

  # Get configuration details
  result.indexMode = $barrel.mode
  result.syncMode = $barrel.config.syncMode

  # Get last modified time
  if fileExists(barrel.path):
    result.lastModified = $getLastModificationTime(barrel.path)


# Helper to generate hint file from barrel's index

proc generateHintFileForBarrel*(barrel: Barrel) =
  ## Generate hint file from barrel's current index
  ## Used after compaction to speed up next recovery
  let hintPath = getHintPath(barrel.path)

  # Build hint entries from the index
  var entries: seq[HintEntry] = @[]

  case barrel.mode
  of bmHash:
    for key, entry in barrel.keyDir.pairs():
      entries.add(HintEntry(
        key: key,
        recordPos: entry.recordPos,
        valueSize: entry.valueSize,
        recordSize: entry.recordSize
      ))
  of bmCritBit:
    for key, entry in barrel.critBit.pairs():
      entries.add(HintEntry(
        key: key,
        recordPos: entry.recordPos,
        valueSize: entry.valueSize,
        recordSize: entry.recordSize
      ))
  of bmHugeCritBit:
    return  # HugeBarrel has its own hint file handling

  # Get current data file size for incremental recovery
  let dataFileSize = if fileExists(barrel.path): getFileSize(barrel.path).uint64 else: 0'u64

  discard writeHintFile(hintPath, barrel.fileId, entries, dataFileSize)

# Compaction operations

proc compactWorkerThread(args: CompactThreadArgs) {.thread.} =
  ## Background compaction worker thread
  ## Note: This is wrapped in try/except to handle the known Nim ORC bug
  ## where thread cleanup can crash. The actual compaction completes successfully.

  try:
    let barrel = cast[Barrel](args.barrelPtr)

    # Perform non-blocking compaction
    # IMPORTANT: Pass a reference to the dataFile, not a copy!
    # DataFile is a value type, so we need to use a pointer to avoid
    # stale size values when main thread writes during compaction.
    var newFilePtr = addr barrel.dataFiles[args.newFileId]
    let success = barrel.compactController.performCompactNonBlocking(
      args.oldPath, args.oldFileId, newFilePtr[]
    )

    {.gcsafe.}:
      if success:
        # Update barrel state
        barrel.fileId = args.newFileId
        barrel.path = barrel.path.replace(fmt("{args.oldFileId:06d}.data"),
                                            fmt("{args.newFileId:06d}.data"))

        # Close and remove old file
        if barrel.dataFiles.hasKey(args.oldFileId):
          barrel.dataFiles[args.oldFileId].close()
          barrel.dataFiles.del(args.oldFileId)

        # Update primary dataFile reference
        barrel.dataFile = barrel.dataFiles[args.newFileId]

        # Delete old data file
        if fileExists(args.oldPath):
          removeFile(args.oldPath)

        # Remove compaction marker
        let dataDir = if parentDir(args.oldPath) == "": "." else: parentDir(args.oldPath)
        removeCompactionMarker(dataDir)

        # Generate hint file for new file
        generateHintFileForBarrel(barrel)
      else:
        # Rollback on failure
        if barrel.dataFiles.hasKey(args.newFileId):
          barrel.dataFiles[args.newFileId].close()
          barrel.dataFiles.del(args.newFileId)

        let newPath = args.oldPath.replace(fmt("{args.oldFileId:06d}.data"),
                                            fmt("{args.newFileId:06d}.data"))
        if fileExists(newPath):
          removeFile(newPath)

        let dataDir = if parentDir(args.oldPath) == "": "." else: parentDir(args.oldPath)
        removeCompactionMarker(dataDir)

      barrel.compactionState.inProgress = false
  except:
    # Silently catch any ORC-related crashes during cleanup
    discard

proc triggerCompact*(barrel: var Barrel): bool =
  ## Trigger non-blocking compaction of the current data file
  ## Returns true if compaction was started, false if already in progress or failed
  ## Compaction runs in a background thread - this returns immediately
  if barrel.closed or barrel.compactController == nil:
    return false

  if barrel.compactionState.inProgress:
    return false  # Already compacting

  case barrel.mode
  of bmHash, bmCritBit:
    let oldFileId = barrel.fileId
    let newFileId = oldFileId + 1
    let compactionStart = getTime().toUnix()
    let oldPath = barrel.path

    # Write compaction marker for crash recovery
    let dataDir = if parentDir(oldPath) == "": "." else: parentDir(oldPath)
    writeCompactionMarker(dataDir, oldFileId, newFileId)

    # Open new file for writes
    let newPath = oldPath.replace(fmt("{oldFileId:06d}.data"),
                                   fmt("{newFileId:06d}.data"))

    # Convert UserSyncMode to storage SyncMode
    var storageSyncMode = syncImmediate
    case barrel.config.syncMode
    of UserSyncMode.None:
      storageSyncMode = syncBuffered
    of UserSyncMode.Sync:
      storageSyncMode = syncImmediate
    of UserSyncMode.Fsync:
      storageSyncMode = syncImmediate

    let newFile = open(newPath, newFileId, storageSyncMode,
                       shouldFsync = (barrel.config.syncMode == UserSyncMode.Fsync),
                       bufferSize = barrel.config.writeBufferSize,
                       validateCrc = barrel.config.validateCrc)
    barrel.dataFiles[newFileId] = newFile

    # Enter compaction state - new writes go to newFile
    barrel.compactionState = CompactionState(
      inProgress: true,
      startTime: compactionStart,
      oldFileId: oldFileId,
      newFileId: newFileId
    )

    # Spawn background thread for compaction
    # Allocate thread on heap so we can join it later
    var threadPtr = create(Thread[CompactThreadArgs])
    let args = CompactThreadArgs(
      barrelPtr: cast[pointer](barrel),
      oldPath: oldPath,
      oldFileId: oldFileId,
      newFileId: newFileId,
      compactionStart: compactionStart
    )
    threadPtr[].createThread(compactWorkerThread, args)
    barrel.compactionThreadPtr = cast[pointer](threadPtr)

    return true  # Return immediately - compaction runs in background

  of bmHugeCritBit:
    raise newException(ValueError, "bmHugeCritBit not yet implemented")

proc isCompacting*(barrel: Barrel): bool =
  ## Check if compaction is currently in progress
  barrel.compactionState.inProgress

proc waitForCompaction*(barrel: Barrel, timeoutMs: int = 30000) =
  ## Wait for compaction to complete (blocking)
  ## timeoutMs: Maximum time to wait in milliseconds (default: 30 seconds)
  let startTime = epochTime()
  while barrel.compactionState.inProgress:
    if (epochTime() - startTime) * 1000 > float(timeoutMs):
      break
    sleep(10)

  # Join the compaction thread after waiting to ensure clean cleanup
  barrel.joinCompactionThread()

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
