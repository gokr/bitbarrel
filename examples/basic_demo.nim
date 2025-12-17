## BitBarrel Demo - Simple GET/SET operations
##
## Run with: nim c -r examples/basic_demo.nim

import std/[os, times, strformat, options]
import bitbarrel/types
import storage
from storage/datafile import open
from storage/keydir import init

proc main() =
  echo "╔════════════════════════════════════════════╗"
  echo "║   BitBarrel Demo: Basic CRUD Operations   ║"
  echo "╚════════════════════════════════════════════╝"
  echo ""

  let dbPath = "examples/demo_basic.data"
  defer:
    if fileExists(dbPath):
      removeFile(dbPath)

  # Initialize
  echo "📁 Opening database..."
  var dataFile = open(dbPath, 1'u32)
  var keyDir = init()
  defer:
    dataFile.close()

  # SET: Store some user data
  echo "\n✍️  Storing user data..."
  let users = @[
    ("user:1", "Alice Johnson"),
    ("user:2", "Bob Smith"),
    ("user:3", "Charlie Brown")
  ]

  for (key, value) in users:
    let ts = getTime().toUnix()
    let info = dataFile.appendRecord(key, value, ts)
    keyDir.add(key, KeyDirEntry(
      fileId: 1,
      recordPos: info.recordPos,
      valuePos: info.valuePos,
      valueSize: info.valueSize,
      timestamp: ts,
      recordSize: info.recordSize
    ))
    echo &"   SET {key} = {value}"

  # GET: Retrieve the data
  echo "\n📖 Reading user data..."
  for (key, expectedValue) in users:
    let found = keyDir.get(key)
    if found.isSome():
      let entry = found.get()
      let recordInfo = RecordInfo(
        recordPos: entry.recordPos,
        valuePos: entry.valuePos,
        valueSize: entry.valueSize,
        recordSize: entry.recordSize
      )
      let (readKey, readValue, ts) = dataFile.readRecord(recordInfo)
      if readValue == expectedValue:
        echo &"   ✅ GET {key} = {readValue}"
      else:
        echo &"   ❌ Mismatch for {key}: expected {expectedValue}, got {readValue}"
    else:
      echo &"   ❌ Key {key} not found"

  # UPDATE: Change a value
  echo "\n🔄 Updating user:1..."
  let updatedValue = "Alice Smith-Johnson"
  let ts = getTime().toUnix()
  let info = dataFile.appendRecord("user:1", updatedValue, ts)
  keyDir.add("user:1", KeyDirEntry(
    fileId: 1,
    recordPos: info.recordPos,
    valuePos: info.valuePos,
    valueSize: info.valueSize,
    timestamp: ts,
    recordSize: info.recordSize
  ))
  echo &"   SET user:1 = {updatedValue}"

  # Verify update
  let found = keyDir.get("user:1")
  if found.isSome():
    let entry = found.get()
    let recordInfo = RecordInfo(
      recordPos: entry.recordPos,
      valuePos: entry.valuePos,
      valueSize: entry.valueSize,
      recordSize: entry.recordSize
    )
    let (key, value, _) = dataFile.readRecord(recordInfo)
    echo &"   ✅ Verified: user:1 = {value}"

  # DELETE (tombstone)
  echo "\n🗑️  Deleting user:2..."
  let delTs = getTime().toUnix()
  let delInfo = dataFile.appendRecord("user:2", "", delTs)  # Empty value = tombstone
  keyDir.add("user:2", KeyDirEntry(
    fileId: 1,
    recordPos: delInfo.recordPos,
    valuePos: delInfo.valuePos,
    valueSize: delInfo.valueSize,
    timestamp: delTs,
    recordSize: delInfo.recordSize
  ))
  echo "   SET user:2 = (tombstone)"

  # Verify deletion
  let delFound = keyDir.get("user:2")
  if delFound.isSome():
    let entry = delFound.get()
    let recordInfo = RecordInfo(
      recordPos: entry.recordPos,
      valuePos: entry.valuePos,
      valueSize: entry.valueSize,
      recordSize: entry.recordSize
    )
    let (key, value, _) = dataFile.readRecord(recordInfo)
    if value.len == 0:
      echo "   ✅ Verified: user:2 is deleted (tombstone)"
    else:
      echo &"   ❌ Expected empty value, got: {value}"

  echo "\n✨ Demo completed successfully!"
  echo &"   Total keys in database: {keyDir.len}"

when isMainModule:
  main()
