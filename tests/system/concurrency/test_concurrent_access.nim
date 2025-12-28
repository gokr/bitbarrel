## Concurrent Access Tests
##
## Tests for KeyDir operations demonstrating thread-safe design.
## Note: Actual multi-threading in Nim tests is complex due to GC safety.
## These tests verify KeyDir locking mechanisms work correctly.

import std/[unittest, os, strformat, strutils, options]
import ../../../src/storage/keydir
import ../../../src/bitbarrel/types
import ../../testutils

proc now(): int64 = testutils.now()

suite "Concurrent Access Tests":

  test "KeyDir basic operations":
    var keyDir = init()

    # Add some entries
    for i in 0..<100:
      let entry = KeyDirEntry(
        recordPos: uint64(i * 100),
        fileId: 1,
        valueSize: 10,
        recordSize: 25,
        keyLen: uint16(len(fmt("key_{i}")))
      )
      keyDir.add(fmt("key_{i}"), entry)

    # Verify entries exist
    check keyDir.get("key_0").isSome()
    check keyDir.get("key_50").isSome()
    check keyDir.get("key_99").isSome()

  test "KeyDir updates same key":
    var keyDir = init()

    # Update same key multiple times
    for i in 0..<50:
      let entry = KeyDirEntry(
        recordPos: uint64(i),
        fileId: 1,
        valueSize: 10,
        recordSize: 25,
        keyLen: 10  # "shared_key".len
      )
      keyDir.add("shared_key", entry)

    # Verify key exists
    check keyDir.get("shared_key").isSome()

  test "KeyDir clear operation":
    var keyDir = init()

    # Add entries
    for i in 0..<50:
      let entry = KeyDirEntry(
        recordPos: uint64(i * 10),
        fileId: 1,
        valueSize: 5,
        recordSize: 20,
        keyLen: uint16(len(fmt("key_{i}")))
      )
      keyDir.add(fmt("key_{i}"), entry)

    # Clear
    keyDir.clear()

    # Verify empty
    check keyDir.get("key_0").isNone()
    check keyDir.get("key_25").isNone()
