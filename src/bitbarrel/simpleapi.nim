## Simple High-Level KVS API
##
## Provides a simplified interface for key-value storage operations
## Based on the SimpleKVS demo, but enhanced with configuration options

import std/[times, options]
import types
import ../storage
import ../storage/datafile
import ../storage/keydir

export types, datafile

type
  UserSyncMode* = enum
    None = "none"
    Sync = "sync"
    Fsync = "fsync"

  SimpleConfig* = object
    writeBufferSize*: int
    syncMode*: UserSyncMode
    autoCompact*: bool
    compactThreshold*: float  # Compact when tombstone ratio exceeds this

  SimpleKVS* = ref object
    dataFile: DataFile
    keyDir: KeyDir
    fileId: uint32
    config: SimpleConfig
    closed: bool

proc defaultConfig*(): SimpleConfig =
  ## Returns default configuration for SimpleKVS
  result = SimpleConfig(
    writeBufferSize: 64 * 1024,  # 64KB
    syncMode: UserSyncMode.Sync,
    autoCompact: true,
    compactThreshold: 0.3
  )

proc open*(path: string, fileId: uint32 = 1'u32, config: SimpleConfig = defaultConfig()): SimpleKVS =
  ## Open a simple key-value store with optional configuration
  result = SimpleKVS()
  result.fileId = fileId
  result.config = config

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
  result.keyDir = init()
  result.closed = false

proc open*(path: string, config: SimpleConfig): SimpleKVS =
  ## Open a simple key-value store with configuration (no fileId needed)
  open(path, 1'u32, config)

proc close*(kvs: SimpleKVS) =
  ## Close the key-value store
  if not kvs.closed:
    kvs.dataFile.close()
    kvs.closed = true

proc set*(kvs: SimpleKVS, key: string, value: string): bool =
  ## Set a key-value pair
  if kvs.closed:
    return false

  let timestamp = getTime().toUnix()
  try:
    let info = kvs.dataFile.appendRecord(key, value, timestamp)
    let entry = KeyDirEntry(
      fileId: kvs.fileId,
      recordPos: info.recordPos,
      valuePos: info.valuePos,
      valueSize: info.valueSize,
      timestamp: timestamp,
      recordSize: info.recordSize
    )
    kvs.keyDir.add(key, entry)
    return true
  except:
    return false

proc get*(kvs: SimpleKVS, key: string): string =
  ## Get a value by key (returns empty string if not found)
  if kvs.closed:
    return ""

  let found = kvs.keyDir.get(key)
  if found.isSome():
    let entry = found.get()
    let recordInfo = RecordInfo(
      recordPos: entry.recordPos,
      valuePos: entry.valuePos,
      valueSize: entry.valueSize,
      recordSize: entry.recordSize
    )
    try:
      let (_, value, _) = kvs.dataFile.readRecord(recordInfo)
      return value
    except:
      return ""
  else:
    return ""

proc delete*(kvs: SimpleKVS, key: string): bool =
  ## Delete a key (using tombstone)
  if kvs.closed:
    return false

  let timestamp = getTime().toUnix()
  try:
    # Write empty value as tombstone
    let info = kvs.dataFile.appendRecord(key, "", timestamp)
    let entry = KeyDirEntry(
      fileId: kvs.fileId,
      recordPos: info.recordPos,
      valuePos: info.valuePos,
      valueSize: info.valueSize,
      timestamp: timestamp,
      recordSize: info.recordSize
    )
    kvs.keyDir.add(key, entry)
    return true
  except:
    return false

proc exists*(kvs: SimpleKVS, key: string): bool =
  ## Check if a key exists (and is not deleted)
  if kvs.closed:
    return false

  let found = kvs.keyDir.get(key)
  if found.isSome():
    let entry = found.get()
    # Check if this is a tombstone (empty value)
    let recordInfo = RecordInfo(
      recordPos: entry.recordPos,
      valuePos: entry.valuePos,
      valueSize: entry.valueSize,
      recordSize: entry.recordSize
    )
    try:
      let (_, value, _) = kvs.dataFile.readRecord(recordInfo)
      return value.len > 0
    except:
      return false
  return false

proc count*(kvs: SimpleKVS): int =
  ## Get number of non-deleted keys in store
  if kvs.closed:
    return 0

  # Since we can't easily distinguish tombstones in KeyDir,
  # we count only non-empty values
  var count = 0
  let keys = kvs.keyDir.keys()
  for key in keys:
    let found = kvs.keyDir.get(key)
    if found.isSome():
      let entry = found.get()
      let recordInfo = RecordInfo(
        recordPos: entry.recordPos,
        valuePos: entry.valuePos,
        valueSize: entry.valueSize,
        recordSize: entry.recordSize
      )
      try:
        let (_, value, _) = kvs.dataFile.readRecord(recordInfo)
        if value.len > 0:
          inc count
      except:
        discard
  return count

proc listKeys*(kvs: SimpleKVS): seq[string] =
  ## List all non-deleted keys in the store
  result = @[]
  if kvs.closed:
    return

  let keys = kvs.keyDir.keys()
  for key in keys:
    let found = kvs.keyDir.get(key)
    if found.isSome():
      let entry = found.get()
      let recordInfo = RecordInfo(
        recordPos: entry.recordPos,
        valuePos: entry.valuePos,
        valueSize: entry.valueSize,
        recordSize: entry.recordSize
      )
      try:
        let (_, value, _) = kvs.dataFile.readRecord(recordInfo)
        if value.len > 0:
          result.add(key)
      except:
        discard

proc clear*(kvs: SimpleKVS): bool =
  ## Clear all keys by creating a fresh data file
  if kvs.closed:
    return false

  # Simple approach: just clear the KeyDir
  # Values remain in file but won't be accessible
  try:
    kvs.keyDir = init()
    return true
  except:
    return false

proc isClosed*(kvs: SimpleKVS): bool =
  ## Check if the KVS is closed
  return kvs.closed

