## Demonstration of KVS basic operations

import os
import times
import ../src/kvs/types
import ../src/storage
from ../src/storage/datafile import open
from ../src/storage/keydir import init

proc main() =
  echo "=== KVS Demo: Basic Operations ==="

  let testPath = "demo.data"

  # Remove existing file
  if fileExists(testPath):
    removeFile(testPath)

  # Create data file and KeyDir
  echo "Creating data file..."
  var dataFile = open(testPath, 1'u32)
  var keyDir = init()

  # SET operation
  echo "\n--- SET Operation ---"
  let key = "user:alice"
  let value = "Alice Johnson"
  let timestamp = getTime().toUnix()

  echo "Writing:", key, "=>", value

  # Write record
  let recordInfo = dataFile.appendRecord(key, value, timestamp)

  # Update KeyDir
  let keyDirEntry = KeyDirEntry(
    fileId: 1,
    valuePos: recordInfo.recordPos,  # Use record position as value position for now
    valueSize: recordInfo.valueSize,
    timestamp: timestamp,
    recordSize: recordInfo.recordSize
  )
  keyDir.add(key, keyDirEntry)
  echo "  - Record written at position:", recordInfo.recordPos
  echo "  - Value position:", recordInfo.valuePos
  echo "  - Record size:", recordInfo.recordSize

  # GET operation
  echo "\n--- GET Operation ---"
  let found = keyDir.get(key)
  if found.isSome():
    let entry = found.get()
    echo "Key found in KeyDir:"
    echo "  - File ID:", entry.fileId
    echo "  - Timestamp:", entry.timestamp
    echo "  - Value size:", entry.valueSize

    # Read actual value from disk
    # Create RecordInfo for reading
    let readRecordInfo = RecordInfo(
      recordPos: entry.valuePos,  # Use valuePos as recordPos
      valuePos: entry.valuePos,
      valueSize: entry.valueSize,
      recordSize: entry.recordSize
    )
    let (readKey, readValue, readTimestamp) = dataFile.readRecord(readRecordInfo)
    echo "Value read from disk:"
    echo "  - Key:", readKey
    echo "  - Value:", readValue
    echo "  - Timestamp:", readTimestamp
  else:
    echo "Key not found!"

  # Test multiple keys
  echo "\n--- Multiple Keys ---"
  let testKeys = [
    ("user:bob", "Bob Smith"),
    ("user:charlie", "Charlie Brown"),
    ("config:max_connections", "1000"),
    ("config:timeout", "30")
  ]

  for (key, value) in testKeys:
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
    echo "Stored:", key, "=>", value

  # Verify all keys
  echo "\n--- Verification ---"
  var foundCount = 0
  for (key, expectedValue) in testKeys:
    let found = keyDir.get(key)
    if found.isSome():
      let (readKey, readValue, _) = dataFile.readRecord(found.get().recordPos)
      if readValue == expectedValue:
        echo "✓", key, "=>", readValue
        inc foundCount
      else:
        echo "✗", key, "- value mismatch. Got:", readValue, "Expected:", expectedValue
    else:
      echo "✗", key, "- not found"

  echo "\nSummary:"
  echo "- Keys in KeyDir:", keyDir.len
  echo "- Successfully verified:", foundCount, "/", testKeys.len

  # File statistics
  echo "\n--- File Statistics ---"
  let header = dataFile.readHeader()
  echo "- Magic: ", header.magic
  echo "- Version: ", header.version
  echo "- File size: ", header.fileSize, " bytes"
  echo "- Created: ", header.created

  dataFile.close()

  # Test persistence
  echo "\n--- Testing Persistence ---"
  echo "Reopening file..."
  dataFile = open(testPath, 1'u32)
  let reopenHeader = dataFile.readHeader()
  echo "File size after reopen: ", reopenHeader.fileSize, " bytes"
  echo "Verification: File still readable ✓"
  dataFile.close()

  # Clean up
  removeFile(testPath)
  echo "\nDemo completed successfully!"

when isMainModule:
  main()