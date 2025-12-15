## Tests for Simple API
##
## Tests the high-level SimpleBB API functionality

import std/[unittest, times, os]
import bitbarrel/simpleapi as bbapi
type SimpleConfig = bbapi.SimpleConfig

suite "SimpleBB API Tests":

  setup:
    let dbPath = "test_simpleapi.data"
    # Remove any existing test database
    if fileExists(dbPath):
      removeFile(dbPath)

  teardown:
    # Clean up test database
    if fileExists(dbPath):
      removeFile(dbPath)

  test "Basic CRUD operations":
    var db = kvsapi.open(dbPath)
    defer: db.close()

    # SET
    check db.set("key1", "value1") == true
    check db.set("key2", "value2") == true
    check db.set("key3", "value3") == true

    # GET
    check:
      db.get("key1") == "value1"
      db.get("key2") == "value2"
      db.get("key3") == "value3"
      db.get("nonexistent") == ""

    # EXISTS
    check:
      db.exists("key1") == true
      db.exists("nonexistent") == false

    # COUNT
    check:
      db.count() == 3

  test "Update operations":
    var db = kvsapi.open(dbPath)
    defer: db.close()

    # Initial set
    check db.set("key", "original") == true
    check db.get("key") == "original"

    # Update
    check db.set("key", "updated") == true
    check db.get("key") == "updated"

    # Should still be 1 key
    check db.count() == 1

  test "Delete operations":
    var db = kvsapi.open(dbPath)
    defer: db.close()

    # Set initial data
    check db.set("key1", "value1") == true
    check db.set("key2", "value2") == true
    check db.set("key3", "value3") == true

    check db.count() == 3

    # Delete
    check db.delete("key2") == true

    # Check after delete
    check:
      db.exists("key1") == true
      db.exists("key2") == false
      db.exists("key3") == true
      db.get("key2") == ""
      db.count() == 2

  test "List keys":
    var db = kvsapi.open(dbPath)
    defer: db.close()

    # Add some keys
    check db.set("a", "value_a") == true
    check db.set("b", "value_b") == true
    check db.set("c", "value_c") == true

    let keys = db.listKeys()
    # Order may vary, so check we have all keys
    check:
      keys.len == 3
      "a" in keys
      "b" in keys
      "c" in keys

  test "Clear database":
    var db = kvsapi.open(dbPath)
    defer: db.close()

    # Add some data
    check db.set("key1", "value1") == true
    check db.set("key2", "value2") == true

    check db.count() == 2

    # Clear
    check db.clear() == true

    check:
      db.count() == 0
      db.get("key1") == ""
      db.get("key2") == ""

  test "Configuration with different sync modes":
    var cfg = kvsapi.defaultConfig()
    cfg.syncMode = kvsapi.UserSyncMode.Fsync
    cfg.writeBufferSize = 32 * 1024

    var db = kvsapi.open(dbPath, cfg)
    defer: db.close()

    # Operations should work with custom config
    check db.set("sync_test", "value") == true
    check db.get("sync_test") == "value"

  test "Closed database operations":
    var db = kvsapi.open(dbPath)

    # Close early
    db.close()

    check db.isClosed() == true

    # Operations on closed database should fail or return defaults
    check:
      db.set("key", "value") == false
      db.get("key") == ""
      db.delete("key") == false
      db.exists("key") == false
      db.count() == 0
      db.listKeys().len == 0

  test "Multiple databases with different paths":
    var db1 = kvsapi.open(dbPath, 1'u32, SimpleConfig())
    var db2 = kvsapi.open(dbPath & "2", 2'u32, SimpleConfig())
    # Use explicit empty config to avoid ambiguity
    defer:
      db1.close()
      db2.close()

    # Set data in both
    discard db1.set("key", "value1")
    discard db2.set("key", "value2")

    # Should have different values
    check:
      db1.get("key") == "value1"
      db2.get("key") == "value2"

  test "Large value storage":
    var db = kvsapi.open(dbPath)
    defer: db.close()

    # Create a large value (10KB)
    var largeValue = newString(10 * 1024)
    for i in 0..<largeValue.len:
      largeValue[i] = chr(ord('a') + (i mod 26))

    check db.set("large_key", largeValue) == true
    check db.get("large_key") == largeValue
    check db.count() == 1

  test "Binary data handling":
    var db = kvsapi.open(dbPath)
    defer: db.close()

    # Test with binary data (including null bytes)
    let binaryData = "\x00\x01\x02\xFF\xFE binary data \x80\x90"

    check db.set("binary_key", binaryData) == true
    check db.get("binary_key") == binaryData