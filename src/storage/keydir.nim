## Key Directory (KeyDir) - In-memory hash index for Bitcask

import std/[tables, locks, options, hashes]
import ../bitbarrel/types

const
  NumKeyDirPartitions = 16

type
  KeyDirPartition* = object
    table*: Table[string, KeyDirEntry]
    lock*: Lock

  KeyDir* = object
    partitions*: array[NumKeyDirPartitions, KeyDirPartition]

proc init*(): KeyDir =
  ## Initialize a new KeyDir with 16 lock-striped partitions
  var keyDir = KeyDir()
  for i in 0..<NumKeyDirPartitions:
    keyDir.partitions[i].table = initTable[string, KeyDirEntry]()
    initLock(keyDir.partitions[i].lock)
  result = keyDir

proc len*(keyDir: var KeyDir): int =
  ## Get the number of entries in the KeyDir
  result = 0
  for i in 0..<NumKeyDirPartitions:
    withLock(keyDir.partitions[i].lock):
      result += keyDir.partitions[i].table.len

proc countActive*(keyDir: var KeyDir): int =
  ## Count active keys (excluding tombstones)
  result = 0
  for i in 0..<NumKeyDirPartitions:
    withLock(keyDir.partitions[i].lock):
      for key, entry in keyDir.partitions[i].table.pairs:
        if not entry.isDeleted():
          inc result

proc countDeleted*(keyDir: var KeyDir): int =
  ## Count deleted keys (tombstones)
  result = 0
  for i in 0..<NumKeyDirPartitions:
    withLock(keyDir.partitions[i].lock):
      for key, entry in keyDir.partitions[i].table.pairs:
        if entry.isDeleted():
          inc result

proc add*(keyDir: var KeyDir, key: string, entry: KeyDirEntry) =
  ## Add or update a key in the KeyDir
  let partition = (hash(key) and 0x7FFFFFFF) mod NumKeyDirPartitions
  withLock(keyDir.partitions[partition].lock):
    keyDir.partitions[partition].table[key] = entry

proc get*(keyDir: var KeyDir, key: string): Option[KeyDirEntry] =
  ## Get a key from the KeyDir
  let partition = (hash(key) and 0x7FFFFFFF) mod NumKeyDirPartitions
  withLock(keyDir.partitions[partition].lock):
    if key in keyDir.partitions[partition].table:
      result = some(keyDir.partitions[partition].table[key])
    else:
      result = none(KeyDirEntry)

proc delete*(keyDir: var KeyDir, key: string): bool =
  ## Delete a key from the KeyDir
  let partition = (hash(key) and 0x7FFFFFFF) mod NumKeyDirPartitions
  withLock(keyDir.partitions[partition].lock):
    if keyDir.partitions[partition].table.contains(key):
      keyDir.partitions[partition].table.del(key)
      result = true
    else:
      result = false

proc clear*(keyDir: var KeyDir) =
  ## Clear all entries from the KeyDir
  for i in 0..<NumKeyDirPartitions:
    withLock(keyDir.partitions[i].lock):
      keyDir.partitions[i].table.clear()

proc contains*(keyDir: var KeyDir, key: string): bool =
  ## Check if a key exists in the KeyDir
  let partition = (hash(key) and 0x7FFFFFFF) mod NumKeyDirPartitions
  withLock(keyDir.partitions[partition].lock):
    result = key in keyDir.partitions[partition].table

proc keys*(keyDir: var KeyDir): seq[string] =
  ## Get all keys in the KeyDir
  result = newSeq[string]()
  for i in 0..<NumKeyDirPartitions:
    withLock(keyDir.partitions[i].lock):
      for key in keyDir.partitions[i].table.keys:
        result.add(key)

proc deinit*(keyDir: var KeyDir) =
  ## Cleanup resources
  for i in 0..<NumKeyDirPartitions:
    deinitLock(keyDir.partitions[i].lock)

iterator pairs*(keyDir: var KeyDir): (string, KeyDirEntry) =
  ## Iterate over all key-entry pairs
  ## Note: Each partition lock is acquired sequentially during iteration
  for i in 0..<NumKeyDirPartitions:
    withLock(keyDir.partitions[i].lock):
      for key, entry in keyDir.partitions[i].table.pairs:
        yield (key, entry)