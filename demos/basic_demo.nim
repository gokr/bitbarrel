## BitBarrel Basic Demo
##
## Demonstrates core CRUD operations using the high-level Barrel API
##
## Run with: nim c -r demos/basic_demo.nim

import std/[os, strformat]
import bitbarrel

proc main() =
  echo "╔════════════════════════════════════════════╗"
  echo "║   BitBarrel Demo: Basic CRUD Operations   ║"
  echo "╚════════════════════════════════════════════╝"
  echo ""

  let dbPath = "demos/data/demo_basic.data"

  # Clean up any existing file
  if fileExists(dbPath):
    removeFile(dbPath)

  # Create temporary data directory if needed
  let dataDir = dbPath.parentDir()
  if not dirExists(dataDir):
    createDir(dataDir)
  defer:
    if fileExists(dbPath):
      removeFile(dbPath)

  # Open barrel with high-level API
  echo "📁 Opening database..."
  var barrel = openBarrel(dbPath)
  defer: barrel.close()
  echo "   ✓ Database opened successfully"
  echo ""

  # SET: Store some user data
  echo "✍️  Storing user data..."
  let users = @[
    ("user:1", "Alice Johnson"),
    ("user:2", "Bob Smith"),
    ("user:3", "Charlie Brown")
  ]

  for (key, value) in users:
    if barrel.set(key, value):
      echo &"   SET {key} = {value}"
    else:
      echo &"   ❌ Failed to set {key}"

  echo &"   ✓ Stored {users.len} keys"
  echo ""

  # GET: Retrieve the data
  echo "📖 Reading user data..."
  for (key, expectedValue) in users:
    let value = barrel.get(key)
    if value == expectedValue:
      echo &"   ✓ GET {key} = {value}"
    else:
      echo &"   ❌ Mismatch for {key}: expected {expectedValue}, got {value}"
  echo ""

  # Check statistics
  echo "📊 Database statistics..."
  echo &"   Total keys: {barrel.count()}"
  echo ""

  # Update barrel statistics
  let totalKeys = barrel.count()
  var foundCount = 0
  for (key, expectedValue) in users:
    if barrel.exists(key):
      let value = barrel.get(key)
      if value == expectedValue:
        inc foundCount
  echo &"   Keys verified: {foundCount}/{totalKeys}"
  echo ""

  # UPDATE: Change a value
  echo "🔄 Updating user:1..."
  let updatedValue = "Alice Smith-Johnson"
  if barrel.set("user:1", updatedValue):
    echo &"   ✓ SET user:1 = {updatedValue}"

    # Verify update
    let value = barrel.get("user:1")
    if value == updatedValue:
      echo &"   ✓ Verified: user:1 = {value}"
    else:
      echo &"   ❌ Verification failed: got {value}"
  else:
    echo "   ❌ Failed to update user:1"
  echo ""

  # DELETE: Remove a key
  echo "🗑️  Deleting user:2..."
  if barrel.delete("user:2"):
    echo "   ✓ DELETE user:2"

    # Verify deletion
    if not barrel.exists("user:2"):
      echo "   ✓ Verified: user:2 no longer exists"
    else:
      echo "   ❌ Key still exists after delete"
  else:
    echo "   ❌ Failed to delete user:2"
  echo ""

  # TTL demo: Set with expiration
  echo "⏰ Testing TTL (Time To Live)..."
  if barrel.set("session:temp", "temporary data", ttl=2):
    echo "   ✓ SET session:temp with 2 second TTL"

    # Check immediately - should still exist
    if barrel.exists("session:temp"):
      echo "   ✓ Session exists immediately after set"

    let remainingTtl = barrel.getTtl("session:temp")
    echo &"   ✓ TTL remaining: ~{remainingTtl} seconds"
  echo ""

  # List all keys
  echo "🔑 Listing all keys..."
  let allKeys = barrel.listKeys()
  for key in allKeys:
    echo &"   - {key}"
  echo ""

  # Persistence demo: Close and reopen
  echo "💾 Testing persistence..."
  let testKey = "persistent:test"
  let testValue = "this should survive a close/reopen"
  discard barrel.set(testKey, testValue)
  echo &"   ✓ Stored {testKey}"

  barrel.close()
  echo "   ✓ Database closed"

  # Reopen to verify persistence
  barrel = openBarrel(dbPath)
  echo "   ✓ Database reopened"

  let persistedValue = barrel.get(testKey)
  if persistedValue == testValue:
    echo &"   ✓ Persistence verified: {persistedValue}"
  else:
    echo &"   ❌ Persistence failed: got {persistedValue}"
  echo ""

  # Config demo: Show current configuration
  echo "⚙️  Current barrel configuration..."
  let config = barrel.getConfig()
  echo &"   Sync mode: {config.syncMode}"
  echo &"   Write buffer size: {config.writeBufferSize} bytes"
  echo &"   Barrel mode: {config.mode}"
  echo &"   Validate CRC: {config.validateCrc}"
  echo ""

  # Final statistics
  echo "✨ Demo completed successfully!"
  echo &"   Total keys in database: {barrel.count()}"
  echo ""
  echo "Key operations demonstrated:"
  echo "  • set(key, value, ttl) - Store a value"
  echo "  • get(key) - Retrieve a value"
  echo "  • delete(key) - Delete a key"
  echo "  • exists(key) - Check if key exists"
  echo "  • count() - Get number of non-deleted keys"
  echo "  • listKeys() - List all keys"
  echo "  • getTtl(key) - Get remaining TTL"
  echo "  • close() / openBarrel() - Persistence"

when isMainModule:
  main()
