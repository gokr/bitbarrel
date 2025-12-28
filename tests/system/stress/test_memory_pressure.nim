## Memory Pressure Tests
##
## Tests for memory usage patterns, KeyDir scaling, and resource management.

import std/[unittest, os, strformat, options, strutils]
import ../../../src/storage/keydir
import ../../../src/storage/datafile
import ../../../src/bitbarrel/types
import ../../testutils

proc now(): int64 = testutils.now()

suite "Memory Pressure Tests":

  test "KeyDir with many entries":
    var keyDir = init()

    const numKeys = 1000
    for i in 0..<numKeys:
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
    check keyDir.get("key_500").isSome()
    check keyDir.get("key_999").isSome()

    # Clear
    keyDir.clear()
    check keyDir.get("key_0").isNone()

  test "DataFile with many small records":
    withTestDir("many_records"):
      let testFile = testDir / "many_records.data"
      var df = datafile.open(testFile, 1'u32)

      const numRecords = 100
      for i in 0..<numRecords:
        discard df.appendRecord(fmt("key_{i}"), fmt("value_{i}"), now())

      df.close()

      # Verify file exists
      check fileExists(testFile)
      check getFileSize(testFile) > 0

  test "Large value handling":
    withTestDir("large_values"):
      let testFile = testDir / "large_values.data"
      var df = datafile.open(testFile, 1'u32)

      # Write records with large values (10KB, 50KB, 100KB)
      for size in [10240, 51200, 102400]:
        let largeValue = repeat("x", size)
        discard df.appendRecord(fmt("large_key_{size}"), largeValue, now())

      df.close()

      # Verify file exists
      check fileExists(testFile)
      check getFileSize(testFile) > 0

  test "Multiple file creation":
    withTestDir("many_files"):
      const numFiles = 20

      for i in 0..<numFiles:
        let file = testDir / fmt("{i:06d}.data")
        var df = datafile.open(file, i.uint32)
        discard df.appendRecord("key", "value", now())
        df.close()

      # Verify all files exist
      for i in 0..<numFiles:
        let file = testDir / fmt("{i:06d}.data")
        check fileExists(file)

  test "KeyDir with long key names":
    var keyDir = init()

    const numKeys = 50
    const keyLength = 200

    for i in 0..<numKeys:
      let longKey = repeat("k", keyLength - 10) & fmt("_{i:06d}")
      let entry = KeyDirEntry(
        recordPos: uint64(i * 100),
        fileId: 1,
        valueSize: 10,
        recordSize: 25,
        keyLen: uint16(longKey.len)
      )
      keyDir.add(longKey, entry)

    # Verify can retrieve entries
    let testKey = repeat("k", keyLength - 10) & "_000025"
    check keyDir.get(testKey).isSome()
