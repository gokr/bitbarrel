## CritBit Index - Ordered key index with range query support
##
## Wraps Nim's stdlib CritBitTree with thread-safe operations
## and provides prefix/range query capabilities.

import std/[critbits, locks, options]
import ../bitbarrel/types

type
  CritBitIndex* = object
    tree*: CritBitTree[KeyDirEntry]
    lock*: Lock

proc init*(): CritBitIndex =
  ## Initialize a new CritBitIndex
  var index = CritBitIndex()
  index.tree = CritBitTree[KeyDirEntry]()
  initLock(index.lock)
  result = index

proc len*(index: var CritBitIndex): int =
  ## Get the number of entries in the index
  withLock(index.lock):
    result = index.tree.len

proc add*(index: var CritBitIndex, key: string, entry: KeyDirEntry) =
  ## Add or update a key in the index
  withLock(index.lock):
    index.tree[key] = entry

proc get*(index: var CritBitIndex, key: string): Option[KeyDirEntry] =
  ## Get a key from the index
  withLock(index.lock):
    if index.tree.contains(key):
      result = some(index.tree[key])
    else:
      result = none(KeyDirEntry)

proc delete*(index: var CritBitIndex, key: string): bool =
  ## Delete a key from the index
  withLock(index.lock):
    if index.tree.contains(key):
      index.tree.excl(key)
      result = true
    else:
      result = false

proc clear*(index: var CritBitIndex) =
  ## Clear all entries from the index
  withLock(index.lock):
    index.tree = CritBitTree[KeyDirEntry]()

proc contains*(index: var CritBitIndex, key: string): bool =
  ## Check if a key exists in the index
  withLock(index.lock):
    result = index.tree.contains(key)

proc keys*(index: var CritBitIndex): seq[string] =
  ## Get all keys in the index (sorted)
  withLock(index.lock):
    result = newSeq[string]()
    for key in index.tree.keys:
      result.add(key)

proc newerEntry*(index: var CritBitIndex, key: string, entry: KeyDirEntry): bool =
  ## Check if the new entry is newer than the existing one
  ## Returns true if the entry should be added
  withLock(index.lock):
    if not index.tree.contains(key):
      return true
    return entry.timestamp > index.tree[key].timestamp

proc addIfNewer*(index: var CritBitIndex, key: string, entry: KeyDirEntry): bool =
  ## Add entry only if it's newer than existing entry
  ## Returns true if entry was added
  withLock(index.lock):
    if not index.tree.contains(key) or entry.timestamp > index.tree[key].timestamp:
      index.tree[key] = entry
      result = true
    else:
      result = false

proc deinit*(index: var CritBitIndex) =
  ## Cleanup resources
  deinitLock(index.lock)

# Range query operations

proc keysWithPrefix*(index: var CritBitIndex, prefix: string): seq[string] =
  ## Get all keys that start with the given prefix (sorted)
  withLock(index.lock):
    result = newSeq[string]()
    for key in index.tree.keysWithPrefix(prefix):
      result.add(key)

proc itemsWithPrefix*(index: var CritBitIndex, prefix: string): seq[(string, KeyDirEntry)] =
  ## Get all key-value pairs where key starts with prefix (sorted)
  withLock(index.lock):
    result = newSeq[(string, KeyDirEntry)]()
    for key in index.tree.keysWithPrefix(prefix):
      result.add((key, index.tree[key]))

proc itemsWithPrefix*(index: var CritBitIndex, prefix: string, limit: int, cursor: string = ""): seq[(string, KeyDirEntry)] =
  ## Get key-value pairs where key starts with prefix with cursor-based pagination
  ## limit: Maximum number of items to return
  ## cursor: Last key from previous page (empty string for first page)
  withLock(index.lock):
    result = newSeq[(string, KeyDirEntry)]()
    var collected = 0
    var started = cursor == ""

    for key in index.tree.keysWithPrefix(prefix):
      # Skip items until after cursor
      if not started:
        if key <= cursor:
          continue
        started = true

      # Skip deleted entries
      let entry = index.tree[key]
      if entry.deleted:
        continue

      # Check limit
      if collected >= limit:
        break

      result.add((key, entry))
      inc collected

proc keysInRange*(index: var CritBitIndex, startKey: string, endKey: string): seq[string] =
  ## Get all keys in the range [startKey, endKey) (sorted)
  ## Uses prefix iteration and filters by range
  withLock(index.lock):
    result = newSeq[string]()
    # Find common prefix between start and end for efficient iteration
    var commonPrefix = ""
    let minLen = min(startKey.len, endKey.len)
    for i in 0..<minLen:
      if startKey[i] == endKey[i]:
        commonPrefix.add(startKey[i])
      else:
        break

    # Iterate keys with common prefix and filter
    for key in index.tree.keysWithPrefix(commonPrefix):
      if key >= startKey and key < endKey:
        result.add(key)

proc itemsInRange*(index: var CritBitIndex, startKey: string, endKey: string): seq[(string, KeyDirEntry)] =
  ## Get all key-value pairs in the range [startKey, endKey) (sorted)
  withLock(index.lock):
    result = newSeq[(string, KeyDirEntry)]()
    # Find common prefix between start and end for efficient iteration
    var commonPrefix = ""
    let minLen = min(startKey.len, endKey.len)
    for i in 0..<minLen:
      if startKey[i] == endKey[i]:
        commonPrefix.add(startKey[i])
      else:
        break

    # Iterate keys with common prefix and filter
    for key in index.tree.keysWithPrefix(commonPrefix):
      if key >= startKey and key < endKey:
        result.add((key, index.tree[key]))

proc itemsInRange*(index: var CritBitIndex, startKey: string, endKey: string, limit: int, cursor: string = ""): seq[(string, KeyDirEntry)] =
  ## Get key-value pairs in range [startKey, endKey) with cursor-based pagination
  ## limit: Maximum number of items to return
  ## cursor: Last key from previous page (empty string for first page)
  withLock(index.lock):
    result = newSeq[(string, KeyDirEntry)]()
    var collected = 0
    var started = cursor == ""

    # Find common prefix between start and end for efficient iteration
    var commonPrefix = ""
    let minLen = min(startKey.len, endKey.len)
    for i in 0..<minLen:
      if startKey[i] == endKey[i]:
        commonPrefix.add(startKey[i])
      else:
        break

    # Iterate keys with common prefix, filter by range and cursor
    for key in index.tree.keysWithPrefix(commonPrefix):
      # Check range first
      if key < startKey or key >= endKey:
        continue

      # Skip items until after cursor
      if not started:
        if key <= cursor:
          continue
        started = true

      # Skip deleted entries
      let entry = index.tree[key]
      if entry.deleted:
        continue

      # Check limit
      if collected >= limit:
        break

      result.add((key, entry))
      inc collected

proc countWithPrefix*(index: var CritBitIndex, prefix: string): int =
  ## Count keys with given prefix
  withLock(index.lock):
    result = 0
    for _ in index.tree.keysWithPrefix(prefix):
      inc result

iterator pairs*(index: var CritBitIndex): (string, KeyDirEntry) =
  ## Iterate over all key-entry pairs (sorted by key)
  ## Note: Lock is held for entire iteration
  withLock(index.lock):
    for key, entry in index.tree.pairs:
      yield (key, entry)

iterator pairsWithPrefix*(index: var CritBitIndex, prefix: string): (string, KeyDirEntry) =
  ## Iterate over key-entry pairs where key starts with prefix
  ## Note: Lock is held for entire iteration
  withLock(index.lock):
    for key in index.tree.keysWithPrefix(prefix):
      yield (key, index.tree[key])

iterator itemsInRange*(index: var CritBitIndex, startKey: string, endKey: string): (string, KeyDirEntry) =
  ## Iterate over key-entry pairs in range [startKey, endKey)
  ## Note: Lock is held for entire iteration
  withLock(index.lock):
    # Find common prefix between start and end for efficient iteration
    var commonPrefix = ""
    let minLen = min(startKey.len, endKey.len)
    for i in 0..<minLen:
      if startKey[i] == endKey[i]:
        commonPrefix.add(startKey[i])
      else:
        break

    # Iterate keys with common prefix and filter
    for key in index.tree.keysWithPrefix(commonPrefix):
      if key >= startKey and key < endKey:
        yield (key, index.tree[key])

iterator itemsWithPrefix*(index: var CritBitIndex, prefix: string): (string, KeyDirEntry) =
  ## Iterate over key-entry pairs where key starts with prefix
  ## Note: Lock is held for entire iteration
  withLock(index.lock):
    for key in index.tree.keysWithPrefix(prefix):
      yield (key, index.tree[key])
