## Key Directory (KeyDir) - In-memory hash index for Bitcask

import std/[tables, locks, options]
import ../bitbarrel/types

type
  KeyDir* = object
    table*: Table[string, KeyDirEntry]
    lock*: Lock

proc init*(): KeyDir =
  ## Initialize a new KeyDir
  var keyDir = KeyDir()
  keyDir.table = initTable[string, KeyDirEntry]()
  initLock(keyDir.lock)
  result = keyDir

proc len*(keyDir: var KeyDir): int =
  ## Get the number of entries in the KeyDir
  withLock(keyDir.lock):
    result = keyDir.table.len

proc countActive*(keyDir: var KeyDir): int =
  ## Count active keys (excluding tombstones)
  withLock(keyDir.lock):
    result = 0
    for key, entry in keyDir.table.pairs:
      if not entry.isDeleted():
        inc result

proc countDeleted*(keyDir: var KeyDir): int =
  ## Count deleted keys (tombstones)
  withLock(keyDir.lock):
    result = 0
    for key, entry in keyDir.table.pairs:
      if entry.isDeleted():
        inc result

proc add*(keyDir: var KeyDir, key: string, entry: KeyDirEntry) =
  ## Add or update a key in the KeyDir
  withLock(keyDir.lock):
    keyDir.table[key] = entry

proc get*(keyDir: var KeyDir, key: string): Option[KeyDirEntry] =
  ## Get a key from the KeyDir
  withLock(keyDir.lock):
    if key in keyDir.table:
      result = some(keyDir.table[key])
    else:
      result = none(KeyDirEntry)

proc delete*(keyDir: var KeyDir, key: string): bool =
  ## Delete a key from the KeyDir
  withLock(keyDir.lock):
    if keyDir.table.contains(key):
      keyDir.table.del(key)
      result = true
    else:
      result = false

proc clear*(keyDir: var KeyDir) =
  ## Clear all entries from the KeyDir
  withLock(keyDir.lock):
    keyDir.table.clear()

proc contains*(keyDir: var KeyDir, key: string): bool =
  ## Check if a key exists in the KeyDir
  withLock(keyDir.lock):
    result = key in keyDir.table

proc keys*(keyDir: var KeyDir): seq[string] =
  ## Get all keys in the KeyDir
  withLock(keyDir.lock):
    result = newSeq[string]()
    for key in keyDir.table.keys:
      result.add(key)

proc deinit*(keyDir: var KeyDir) =
  ## Cleanup resources
  deinitLock(keyDir.lock)

iterator pairs*(keyDir: var KeyDir): (string, KeyDirEntry) =
  ## Iterate over all key-entry pairs
  ## Note: Lock is held for entire iteration
  withLock(keyDir.lock):
    for key, entry in keyDir.table.pairs:
      yield (key, entry)