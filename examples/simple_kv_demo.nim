## Simple High-Level BitBarrel Demo
##
## Demonstrates simplified API with automatic KeyDir management
## Run with: nim c -r examples/simple_kv_demo.nim

import os
import times
import strformat
import options
import ../src/bitbarrel/types
import ../src/storage
import ../src/storage/datafile
from ../src/storage/keydir import init

proc formatNumber(n: int64): string =
  ## Format large numbers with commas
  let s = $n
  result = ""
  for i, c in s:
    if i > 0 and (s.len - i) mod 3 == 0:
      result.add '_'
    result.add c

type
  SimpleBB* = ref object
    dataFile: DataFile
    keyDir: KeyDir
    fileId: uint32

proc open*(path: string, fileId: uint32): SimpleBB =
  ## Open a simple key-value store
  result = SimpleBB()
  result.fileId = fileId
  result.dataFile = datafile.open(path, fileId)
  result.keyDir = init()

proc close*(barrel: SimpleBB) =
  ## Close the key-value store
  barrel.dataFile.close()
  # Note: KeyDir cleanup handled by GC

proc set*(barrel: SimpleBB, key: string, value: string): bool =
  ## Set a key-value pair
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
  ## Check if a key exists
  return barrel.keyDir.contains(key)

proc count*(barrel: SimpleBB): int =
  ## Get number of keys in store
  return barrel.keyDir.len

proc main() =
  echo "╔════════════════════════════════════════════╗"
  echo "║  Simple BitBarrel Demo: High-Level API          ║"
  echo "╚════════════════════════════════════════════╝"
  echo ""

  let dbPath = "examples/simple_kv.data"
  defer:
    if fileExists(dbPath):
      removeFile(dbPath)

  # Open database
  echo "📂 Opening SimpleBB..."
  var db = open(dbPath, 1'u32)
  defer:
    echo "\n📂 Closing database..."
    db.close()

  # SET operations
  echo "\n✍️  Storing data..."
  discard db.set("name", "Alice Johnson")
  discard db.set("age", "30")
  discard db.set("city", "San Francisco")
  echo "   Stored 3 key-value pairs"

  # GET operations
  echo "\n📖 Retrieving data..."
  let name = db.get("name")
  let ageValue = db.get("age")
  let city = db.get("city")
  echo &"   name: {name}"
  echo &"   age: {ageValue}"
  echo &"   city: {city}"

  # EXISTS checks
  echo "\n🔍 Checking existence..."
  let nameExists = db.exists("name")
  let nonexistentExists = db.exists("nonexistent")
  echo &"   'name' exists: {nameExists}"
  echo &"   'nonexistent' exists: {nonexistentExists}"

  # UPDATE operation
  echo "\n🔄 Updating data..."
  discard db.set("age", "31")  # Updates existing key
  let updatedAge = db.get("age")
  echo &"   Updated age to: {updatedAge}"

  # DELETE operation
  echo "\n🗑️  Deleting data..."
  let beforeCount = db.count()
  echo &"   Before delete - count: {beforeCount}"
  discard db.delete("city")
  let afterCount = db.count()
  echo &"   After delete - count: {afterCount}"
  let cityExists = db.exists("city")
  let cityValue = db.get("city")
  echo &"   'city' exists: {cityExists}"
  echo &"   city value: '{cityValue}' (empty = deleted)"

  # Batch operations
  echo "\n📦 Batch operations..."
  let items = @[("key1", "value1"), ("key2", "value2"), ("key3", "value3")]
  for (k, v) in items:
    discard db.set(k, v)
  echo &"   Added {items.len} items, total count: {db.count()}"

  # Final statistics
  echo "\n📊 Final Statistics:"
  echo &"   Total keys: {db.count()}"
  echo &"   Database file size: {formatNumber(getFileSize(dbPath).int64)} bytes"

  echo "\n✨ SimpleBB demo completed!"

when isMainModule:
  main()
