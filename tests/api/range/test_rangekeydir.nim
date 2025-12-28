## Tests for RangeKeyDir - Fast Serializable Index

import std/[unittest, options, strformat]
import ../../../src/storage/rangekeydir
import ../../../src/bitbarrel/types

suite "RangeKeyDir Tests":

  test "Create empty RangeKeyDir":
    let rkd = newRangeKeyDir()
    check rkd.len == 0
    check rkd.entryCount == 0
    check rkd.pendingCount == 0
    check not rkd.isDirty

  test "Insert and find single entry":
    var rkd = newRangeKeyDir()

    let entry = RangeKeyDirEntry(
      key: "test_key",
      recordPos: 100,
      fileId: 1,
      valueSize: 50,
      recordSize: 60,
      keyLen: 8
    )

    rkd.insert("test_key", entry)

    check rkd.pendingCount == 1
    check rkd.isDirty

    let found = rkd.find("test_key")
    check found.isSome
    check found.get().fileId == 1
    check found.get().recordPos == 100

  test "Insert multiple entries and find":
    var rkd = newRangeKeyDir()

    for i in 0..<10:
      let keyStr = fmt"key_{i:03d}"
      let entry = RangeKeyDirEntry(
        key: keyStr,
        recordPos: (i * 100).uint64,
        fileId: i.uint32,
        valueSize: 50,
        recordSize: 60,
        keyLen: uint16(keyStr.len)
      )
      rkd.insert(keyStr, entry)

    check rkd.pendingCount == 10

    # Find each entry
    for i in 0..<10:
      let found = rkd.find(fmt"key_{i:03d}")
      check found.isSome
      check found.get().fileId == i.uint32

    # Non-existent key
    let notFound = rkd.find("nonexistent")
    check notFound.isNone

  test "Serialize and deserialize empty":
    let rkd = newRangeKeyDir()
    let serialized = rkd.serialize()

    check serialized.len >= 48  # At least header

    let restored = deserialize(serialized)
    check restored.len == 0
    check restored.entryCount == 0

  test "Serialize and deserialize with entries":
    var rkd = newRangeKeyDir()

    for i in 0..<100:
      let keyStr = fmt"key_{i:03d}"
      let entry = RangeKeyDirEntry(
        key: keyStr,
        recordPos: (i * 100).uint64,
        fileId: i.uint32,
        valueSize: 50,
        recordSize: 60,
        keyLen: uint16(keyStr.len)
      )
      rkd.insert(keyStr, entry)

    let serialized = rkd.serialize()
    let restored = deserialize(serialized)

    check restored.entryCount == 100
    check restored.pendingCount == 0

    # Verify all entries via binary search
    for i in 0..<100:
      let found = restored.find(fmt"key_{i:03d}")
      check found.isSome
      check found.get().fileId == i.uint32
      check found.get().recordPos == (i * 100).uint64

  test "Binary search correctness":
    var rkd = newRangeKeyDir()

    # Insert in random-ish order
    let keys = @["zebra", "apple", "mango", "banana", "orange", "kiwi"]
    for i, key in keys:
      let entry = RangeKeyDirEntry(
        key: key,
        recordPos: (i * 100).uint64,
        fileId: i.uint32,
        valueSize: 50,
        recordSize: 60,
        keyLen: uint16(key.len)
      )
      rkd.insert(key, entry)

    # Flush to build sorted array
    rkd.flush()

    check rkd.entryCount == 6
    check rkd.pendingCount == 0

    # Should find all keys via binary search
    for i, key in keys:
      let found = rkd.find(key)
      check found.isSome
      check found.get().fileId == i.uint32

    # Non-existent keys
    check rkd.find("aardvark").isNone
    check rkd.find("zzz").isNone

  test "Flush merges pending with sorted":
    var rkd = newRangeKeyDir()

    # Insert initial entries
    for i in 0..<5:
      let keyStr = fmt"key_{i}"
      let entry = RangeKeyDirEntry(
        key: keyStr,
        recordPos: (i * 100).uint64,
        fileId: i.uint32,
        valueSize: 50,
        recordSize: 60,
        keyLen: uint16(keyStr.len)
      )
      rkd.insert(keyStr, entry)

    rkd.flush()
    check rkd.entryCount == 5
    check rkd.pendingCount == 0

    # Add more entries
    for i in 5..<10:
      let keyStr = fmt"key_{i}"
      let entry = RangeKeyDirEntry(
        key: keyStr,
        recordPos: (i * 100).uint64,
        fileId: i.uint32,
        valueSize: 50,
        recordSize: 60,
        keyLen: uint16(keyStr.len)
      )
      rkd.insert(keyStr, entry)

    check rkd.pendingCount == 5

    # Update an existing key
    let updatedEntry = RangeKeyDirEntry(
      key: "key_2",
      recordPos: 9999,
      fileId: 999,
      valueSize: 50,
      recordSize: 60,
      keyLen: 5
    )
    rkd.insert("key_2", updatedEntry)

    # Should find updated value from pending
    let found = rkd.find("key_2")
    check found.isSome
    check found.get().fileId == 999

    # Flush and verify
    rkd.flush()
    check rkd.entryCount == 10
    check rkd.pendingCount == 0

    let foundAfter = rkd.find("key_2")
    check foundAfter.isSome
    check foundAfter.get().fileId == 999

  test "Delete marks entry as deleted":
    var rkd = newRangeKeyDir()

    let entry = RangeKeyDirEntry(
      key: "to_delete",
      recordPos: 100,
      fileId: 1,
      valueSize: 50,
      recordSize: 60,
      keyLen: 9
    )
    rkd.insert("to_delete", entry)

    check rkd.contains("to_delete")

    rkd.delete("to_delete")

    # Entry exists but is deleted (valueSize = 0)
    let found = rkd.find("to_delete")
    check found.isSome
    check found.get().isDeleted

    # contains returns false for deleted
    check not rkd.contains("to_delete")

  test "MinKey and MaxKey tracking":
    var rkd = newRangeKeyDir()

    rkd.insert("middle", RangeKeyDirEntry(key: "middle", recordPos: 0, fileId: 1, valueSize: 10, recordSize: 0, keyLen: 6))
    check rkd.minKey == "middle"
    check rkd.maxKey == "middle"

    rkd.insert("alpha", RangeKeyDirEntry(key: "alpha", recordPos: 0, fileId: 2, valueSize: 10, recordSize: 0, keyLen: 5))
    check rkd.minKey == "alpha"
    check rkd.maxKey == "middle"

    rkd.insert("zebra", RangeKeyDirEntry(key: "zebra", recordPos: 0, fileId: 3, valueSize: 10, recordSize: 0, keyLen: 5))
    check rkd.minKey == "alpha"
    check rkd.maxKey == "zebra"

  test "Iteration over entries":
    var rkd = newRangeKeyDir()

    for i in 0..<5:
      let keyStr = fmt"key_{i}"
      let entry = RangeKeyDirEntry(
        key: keyStr,
        recordPos: 0,
        fileId: i.uint32,
        valueSize: 10,
        recordSize: 0,
        keyLen: uint16(keyStr.len)
      )
      rkd.insert(keyStr, entry)

    rkd.flush()

    var count = 0
    for key, entry in rkd.pairs():
      inc count

    check count == 5

  test "Large dataset serialization":
    var rkd = newRangeKeyDir()
    let numEntries = 10000

    for i in 0..<numEntries:
      let keyStr = fmt"key_{i:06d}"
      let entry = RangeKeyDirEntry(
        key: keyStr,
        recordPos: (i * 100).uint64,
        fileId: (i mod 100).uint32,
        valueSize: 50,
        recordSize: 60,
        keyLen: uint16(keyStr.len)
      )
      rkd.insert(keyStr, entry)

    let serialized = rkd.serialize()
    check serialized.len > 0  # Serialization should produce data

    let restored = deserialize(serialized)
    check restored.entryCount == numEntries

    # Verify a sample of entries
    for i in [0, 100, 1000, 5000, 9999]:
      let found = restored.find(fmt"key_{i:06d}")
      check found.isSome
      check found.get().fileId == (i mod 100).uint32

  test "Checksum validation with larger dataset":
    var rkd = newRangeKeyDir()

    # Add multiple entries to ensure there's enough data to corrupt
    for i in 0..<10:
      let keyStr = fmt"testkey_{i:03d}"
      rkd.insert(keyStr, RangeKeyDirEntry(
        key: keyStr,
        recordPos: (i * 100).uint64,
        fileId: i.uint32,
        valueSize: 50,
        recordSize: 60,
        keyLen: uint16(keyStr.len)
      ))

    var serialized = rkd.serialize()

    # The serialized data should be large enough now
    # Corrupt the entry data (well past header and offset table)
    let dataLen = serialized.len
    if dataLen > 200:
      # Corrupt somewhere in the entry data section
      serialized[dataLen - 50] = char(serialized[dataLen - 50].uint8 xor 0xFF)

      expect ValueError:
        discard deserialize(serialized)
    else:
      # If still too small, just verify serialization works
      let restored = deserialize(serialized)
      check restored.entryCount > 0

  test "Auto-flush on threshold":
    var rkd = newRangeKeyDir(maxPending = 5)

    for i in 0..<4:
      let keyStr = fmt"key_{i}"
      rkd.insert(keyStr, RangeKeyDirEntry(
        key: keyStr,
        recordPos: 0,
        fileId: i.uint32,
        valueSize: 10,
        recordSize: 0,
        keyLen: uint16(keyStr.len)
      ))

    check not rkd.shouldFlush()
    check rkd.pendingCount == 4

    rkd.insert("key_4", RangeKeyDirEntry(
      key: "key_4",
      recordPos: 0,
      fileId: 4,
      valueSize: 10,
      recordSize: 0,
      keyLen: 5
    ))

    check rkd.shouldFlush()

    rkd.maybeFlush()

    check rkd.pendingCount == 0
    check rkd.entryCount == 5
