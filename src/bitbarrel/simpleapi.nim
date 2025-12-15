## Simple High-Level KVS API
##
## Provides a simplified interface for key-value storage operations
## Based on the SimpleBB demo, but enhanced with configuration options

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

  SimpleBB* = ref object
    dataFile: DataFile
    keyDir: KeyDir
    fileId: uint32
    config: SimpleConfig
    closed: bool

proc defaultConfig*(): SimpleConfig =
  ## Returns default configuration for SimpleBB
  result = SimpleConfig(
    writeBufferSize: 64 * 1024,  # 64KB
    syncMode: UserSyncMode.Sync,
    autoCompact: true,
    compactThreshold: 0.3
  )

proc open*(path: string, fileId: uint32 = 1'u32, config: SimpleConfig = defaultConfig()): SimpleBB =
  ## Open a simple key-value store with optional configuration
  result = SimpleBB()
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

proc open*(path: string, config: SimpleConfig): SimpleBB =
  ## Open a simple key-value store with configuration (no fileId needed)
  open(path, 1'u32, config)

proc close*(barrel: SimpleBB) =
  ## Close the key-value store
  if not barrel.closed:
    barrel.dataFile.close()
    barrel.closed = true

proc set*(barrel: SimpleBB, key: string, value: string): bool =
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
    barrel.keyDir.add(key, entry)
    return true
  except:
    return false

proc get*(barrel: SimpleBB, key: string): string =
  ## Get a value by key (returns empty string if not found)
  if barrel.closed:
    return ""

  let found = barrel.keyDir.get(key)
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

proc delete*(barrel: SimpleBB, key: string): bool =
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
    barrel.keyDir.add(key, entry)
    return true
  except:
    return false

proc exists*(barrel: SimpleBB, key: string): bool =
  ## Check if a key exists (and is not deleted)
  if barrel.closed:
    return false

  let found = barrel.keyDir.get(key)
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
      let (_, value, _) = barrel.dataFile.readRecord(recordInfo)
      return value.len > 0
    except:
      return false
  return false

proc count*(barrel: SimpleBB): int =
  ## Get number of non-deleted keys in store
  if barrel.closed:
    return 0

  # Since we can't easily distinguish tombstones in KeyDir,
  # we count only non-empty values
  var count = 0
  let keys = barrel.keyDir.keys()
  for key in keys:
    let found = barrel.keyDir.get(key)
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

proc listKeys*(barrel: SimpleBB): seq[string] =
  ## List all non-deleted keys in the store
  result = @[]
  if barrel.closed:
    return

  let keys = barrel.keyDir.keys()
  for key in keys:
    let found = barrel.keyDir.get(key)
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

proc clear*(barrel: SimpleBB): bool =
  ## Clear all keys by creating a fresh data file
  if barrel.closed:
    return false

  # Simple approach: just clear the KeyDir
  # Values remain in file but won't be accessible
  try:
    barrel.keyDir = init()
    return true
  except:
    return false

proc isClosed*(barrel: SimpleBB): bool =
  ## Check if the KVS is closed
  return barrel.closed

