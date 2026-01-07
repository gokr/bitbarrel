## Embedded Smoke Test for BitBarrel CLI
##
## Basic functionality test: write, read, delete verification
## Usage: call runEmbeddedTest() which returns true on success

import std/[os, strformat, strutils]
import ../bitbarrel

const
  NUM_KEYS = 1000
  NUM_DELETES = 500

proc runEmbeddedTest*(): bool =
  ## Run embedded smoke test: write, read, delete verification
  ## Returns true on success, false on failure

  let dbFile = "bitbarrel_smoke_test.dat"

  echo ""
  echo "============================================================"
  echo "                BitBarrel Smoke Test"
  echo "============================================================"
  echo ""

  # Clean up any existing test data
  if fileExists(dbFile):
    removeFile(dbFile)

  echo &"Opening database: {dbFile}"
  let bb = openDatabase(dbFile)
  if bb == nil:
    echo "Error: Failed to open database"
    return false

  # Phase 1: Write keys
  echo ""
  echo &"Phase 1: Writing {NUM_KEYS} key-value pairs..."

  for i in 0..<NUM_KEYS:
    let key = &"smoke_key_{i:03d}"
    let value = &"smoke_value_{i:03d}_{'x'.repeat(20)}"
    let success = bb.set(key, value)
    if not success:
      echo &"  Error: Failed to write key {key}"
      bb.close()
      removeFile(dbFile)
      return false

  echo &"  Wrote {NUM_KEYS} keys successfully"

  # Phase 2: Read and verify keys
  echo ""
  echo &"Phase 2: Reading and verifying {NUM_KEYS} keys..."

  for i in 0..<NUM_KEYS:
    let key = &"smoke_key_{i:03d}"
    let expectedValue = &"smoke_value_{i:03d}_{'x'.repeat(20)}"
    let value = bb.get(key)

    if value.len == 0:
      echo &"  Error: Key not found: {key}"
      bb.close()
      removeFile(dbFile)
      return false

    if value != expectedValue:
      echo &"  Error: Value mismatch for key {key}"
      echo &"    Expected: {expectedValue}"
      echo &"    Got:      {value}"
      bb.close()
      removeFile(dbFile)
      return false

  echo &"  Verified {NUM_KEYS} keys successfully"

  # Phase 3: Delete some keys
  echo ""
  echo &"Phase 3: Deleting {NUM_DELETES} keys..."

  for i in 0..<NUM_DELETES:
    let key = &"smoke_key_{i:03d}"
    let success = bb.delete(key)
    if not success:
      echo &"  Error: Failed to delete key {key}"
      bb.close()
      removeFile(dbFile)
      return false

  echo &"  Deleted {NUM_DELETES} keys successfully"

  # Phase 4: Verify deleted keys raise error
  echo ""
  echo "Phase 4: Verifying deleted keys return empty..."

  var verifiedDeletions = 0
  for i in 0..<NUM_DELETES:
    let key = &"smoke_key_{i:03d}"
    let value = bb.get(key)

    if value.len > 0:
      echo &"  Error: Deleted key still exists: {key}"
      bb.close()
      removeFile(dbFile)
      return false
    verifiedDeletions += 1

  echo &"  Verified {verifiedDeletions} deletions successfully"

  # Phase 5: Verify remaining keys still exist
  echo ""
  echo &"Phase 5: Verifying remaining {NUM_KEYS - NUM_DELETES} keys..."

  for i in NUM_DELETES..<NUM_KEYS:
    let key = &"smoke_key_{i:03d}"
    let value = bb.get(key)

    if value.len == 0:
      echo &"  Error: Key missing: {key}"
      bb.close()
      removeFile(dbFile)
      return false

  echo &"  Verified {NUM_KEYS - NUM_DELETES} remaining keys successfully"

  bb.close()
  removeFile(dbFile)

  echo ""
  echo "============================================================"
  echo &"  Write test:   {NUM_KEYS} keys - PASSED"
  echo &"  Read test:    {NUM_KEYS} keys - PASSED"
  echo &"  Delete test:  {NUM_DELETES} keys - PASSED"
  echo "============================================================"
  echo ""
  echo "Smoke test completed successfully!"

  return true