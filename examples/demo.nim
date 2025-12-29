## Demonstration of BitBarrel basic operations

import os
import times
import options
import ../src/bitbarrel/types
import ../src/storage
from ../src/storage/datafile import open
from ../src/storage/keydir import init

proc main() =
  echo "=== BitBarrel Demo: Basic Operations ==="

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
    recordPos: recordInfo.recordPos,
    valueSize: recordInfo.valueSize,
    recordSize: recordInfo.recordSize,
    keyLen: recordInfo.keyLen
  )
  keyDir.add(key, keyDirEntry)
  echo "  - Record written at position:", recordInfo.recordPos
  echo "  - Record size:", recordInfo.recordSize

  # GET operation
  echo "\n--- GET Operation ---"
  let found = keyDir.get(key)
  if found.isSome():
    let entry = found.get()
    echo "Key found in KeyDir:"
    echo "  - File ID:", entry.fileId
    echo "  - Value size:", entry.valueSize

    # Read actual value from disk
    # Create RecordInfo for reading
    let readRecordInfo = RecordInfo(
      recordPos: entry.recordPos,
      valueSize: entry.valueSize,
      recordSize: entry.recordSize,
      keyLen: entry.keyLen
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
      valueSize: info.valueSize,
      recordSize: info.recordSize,
      keyLen: info.keyLen
    ))
    echo "Stored:", key, "=>", value

  # Verify all keys
  echo "\n--- Verification ---"
  var foundCount = 0
  for (key, expectedValue) in testKeys:
    let found = keyDir.get(key)
    if found.isSome():
      let entry = found.get()
      let recordInfo = RecordInfo(
        recordPos: entry.recordPos,
        valueSize: entry.valueSize,
        recordSize: entry.recordSize,
        keyLen: entry.keyLen
      )
      let (_, readValue, _) = dataFile.readRecord(recordInfo)
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