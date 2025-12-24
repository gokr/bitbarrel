## Tests for RangeKeyDir - Fast Serializable Index

import std/[unittest, options, times, tables, sequtils, strformat]
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
      fileId: 1,
      recordPos: 100,
      valuePos: 110,
      valueSize: 50,
      timestamp: getTime().toUnix(),
      recordSize: 60,
      deleted: false
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
      let entry = RangeKeyDirEntry(
        key: fmt"key_{i:03d}",
        fileId: i.uint32,
        recordPos: (i * 100).uint64,
        valuePos: (i * 100 + 10).uint64,
        valueSize: 50,
        timestamp: getTime().toUnix(),
        recordSize: 60,
        deleted: false
      )
      rkd.insert(fmt"key_{i:03d}", entry)

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
      let entry = RangeKeyDirEntry(
        key: fmt"key_{i:03d}",
        fileId: i.uint32,
        recordPos: (i * 100).uint64,
        valuePos: (i * 100 + 10).uint64,
        valueSize: 50,
        timestamp: getTime().toUnix(),
        recordSize: 60,
        deleted: false
      )
      rkd.insert(fmt"key_{i:03d}", entry)

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
    let rkd = newRangeKeyDir()

    # Insert in random-ish order
    let keys = @["zebra", "apple", "mango", "banana", "orange", "kiwi"]
    for i, key in keys:
      let entry = RangeKeyDirEntry(
        key: key,
        fileId: i.uint32,
        recordPos: (i * 100).uint64,
        valuePos: (i * 100 + 10).uint64,
        valueSize: 50,
        timestamp: getTime().toUnix(),
        recordSize: 60,
        deleted: false
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
    let rkd = newRangeKeyDir()

    # Insert initial entries
    for i in 0..<5:
      let entry = RangeKeyDirEntry(
        key: fmt"key_{i}",
        fileId: i.uint32,
        recordPos: (i * 100).uint64,
        valuePos: (i * 100 + 10).uint64,
        valueSize: 50,
        timestamp: getTime().toUnix(),
        recordSize: 60,
        deleted: false
      )
      rkd.insert(fmt"key_{i}", entry)

    rkd.flush()
    check rkd.entryCount == 5
    check rkd.pendingCount == 0

    # Add more entries
    for i in 5..<10:
      let entry = RangeKeyDirEntry(
        key: fmt"key_{i}",
        fileId: i.uint32,
        recordPos: (i * 100).uint64,
        valuePos: (i * 100 + 10).uint64,
        valueSize: 50,
        timestamp: getTime().toUnix(),
        recordSize: 60,
        deleted: false
      )
      rkd.insert(fmt"key_{i}", entry)

    check rkd.pendingCount == 5

    # Update an existing key
    let updatedEntry = RangeKeyDirEntry(
      key: "key_2",
      fileId: 999,
      recordPos: 9999,
      valuePos: 9999,
      valueSize: 50,
      timestamp: getTime().toUnix(),
      recordSize: 60,
      deleted: false
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
    let rkd = newRangeKeyDir()

    let entry = RangeKeyDirEntry(
      key: "to_delete",
      fileId: 1,
      recordPos: 100,
      valuePos: 110,
      valueSize: 50,
      timestamp: getTime().toUnix(),
      recordSize: 60,
      deleted: false
    )
    rkd.insert("to_delete", entry)

    check rkd.contains("to_delete")

    rkd.delete("to_delete")

    # Entry exists but is deleted
    let found = rkd.find("to_delete")
    check found.isSome
    check found.get().deleted

    # contains returns false for deleted
    check not rkd.contains("to_delete")

  test "MinKey and MaxKey tracking":
    let rkd = newRangeKeyDir()

    rkd.insert("middle", RangeKeyDirEntry(key: "middle", fileId: 1, recordPos: 0, valuePos: 0, valueSize: 0, timestamp: 0, recordSize: 0, deleted: false))
    check rkd.minKey == "middle"
    check rkd.maxKey == "middle"

    rkd.insert("alpha", RangeKeyDirEntry(key: "alpha", fileId: 2, recordPos: 0, valuePos: 0, valueSize: 0, timestamp: 0, recordSize: 0, deleted: false))
    check rkd.minKey == "alpha"
    check rkd.maxKey == "middle"

    rkd.insert("zebra", RangeKeyDirEntry(key: "zebra", fileId: 3, recordPos: 0, valuePos: 0, valueSize: 0, timestamp: 0, recordSize: 0, deleted: false))
    check rkd.minKey == "alpha"
    check rkd.maxKey == "zebra"

  test "Iteration over entries":
    let rkd = newRangeKeyDir()

    for i in 0..<5:
      let entry = RangeKeyDirEntry(
        key: fmt"key_{i}",
        fileId: i.uint32,
        recordPos: 0,
        valuePos: 0,
        valueSize: 0,
        timestamp: 0,
        recordSize: 0,
        deleted: false
      )
      rkd.insert(fmt"key_{i}", entry)

    rkd.flush()

    var count = 0
    for key, entry in rkd.pairs():
      inc count

    check count == 5

  test "Large dataset serialization":
    let rkd = newRangeKeyDir()
    let numEntries = 10000

    for i in 0..<numEntries:
      let entry = RangeKeyDirEntry(
        key: fmt"key_{i:06d}",
        fileId: (i mod 100).uint32,
        recordPos: (i * 100).uint64,
        valuePos: (i * 100 + 10).uint64,
        valueSize: 50,
        timestamp: getTime().toUnix(),
        recordSize: 60,
        deleted: false
      )
      rkd.insert(fmt"key_{i:06d}", entry)

    let serialized = rkd.serialize()
    echo fmt"Serialized {numEntries} entries to {serialized.len} bytes ({serialized.len / numEntries:.1f} bytes/entry)"

    let restored = deserialize(serialized)
    check restored.entryCount == numEntries

    # Verify a sample of entries
    for i in [0, 100, 1000, 5000, 9999]:
      let found = restored.find(fmt"key_{i:06d}")
      check found.isSome
      check found.get().fileId == (i mod 100).uint32

  test "Checksum validation":
    let rkd = newRangeKeyDir()

    rkd.insert("test", RangeKeyDirEntry(
      key: "test",
      fileId: 1,
      recordPos: 100,
      valuePos: 110,
      valueSize: 50,
      timestamp: getTime().toUnix(),
      recordSize: 60,
      deleted: false
    ))

    var serialized = rkd.serialize()

    # Corrupt the data
    if serialized.len > 100:
      serialized[100] = char(serialized[100].uint8 xor 0xFF)

    expect ValueError:
      discard deserialize(serialized)

  test "Auto-flush on threshold":
    let rkd = newRangeKeyDir(maxPending = 5)

    for i in 0..<4:
      rkd.insert(fmt"key_{i}", RangeKeyDirEntry(
        key: fmt"key_{i}",
        fileId: i.uint32,
        recordPos: 0,
        valuePos: 0,
        valueSize: 0,
        timestamp: 0,
        recordSize: 0,
        deleted: false
      ))

    check not rkd.shouldFlush()
    check rkd.pendingCount == 4

    rkd.insert("key_4", RangeKeyDirEntry(
      key: "key_4",
      fileId: 4,
      recordPos: 0,
      valuePos: 0,
      valueSize: 0,
      timestamp: 0,
      recordSize: 0,
      deleted: false
    ))

    check rkd.shouldFlush()

    rkd.maybeFlush()

    check rkd.pendingCount == 0
    check rkd.entryCount == 5

echo "Running RangeKeyDir tests..."
