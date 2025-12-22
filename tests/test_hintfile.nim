## Tests for hint file implementation

import std/[unittest, os, times, strformat, options]
import ../src/bitbarrel/types
import ../src/storage/hintfile
import ../src/storage/keydir
import testutils

suite "Hint File Tests":

  test "Write and read empty hint file":
    withTestDir("hintfile_empty"):
      let path = testDir / "test.hint"
      let entries: seq[HintEntry] = @[]

      let writeSuccess = writeHintFile(path, 1, entries)
      check writeSuccess == true
      check fileExists(path)

      let (header, readEntries, readSuccess) = readHintFile(path)
      check readSuccess == true
      check header.magic == HINT_MAGIC
      check header.version == HINT_VERSION
      check header.entryCount == 0
      check header.dataFileId == 1
      check readEntries.len == 0

  test "Write and read hint file with entries":
    withTestDir("hintfile_entries"):
      let path = testDir / "test.hint"
      let entries = @[
        HintEntry(key: "key1", recordPos: 100, valuePos: 120, valueSize: 10, timestamp: 1000, recordSize: 30),
        HintEntry(key: "key2", recordPos: 200, valuePos: 220, valueSize: 20, timestamp: 2000, recordSize: 40),
        HintEntry(key: "key3", recordPos: 300, valuePos: 320, valueSize: 30, timestamp: 3000, recordSize: 50)
      ]

      let writeSuccess = writeHintFile(path, 42, entries)
      check writeSuccess == true

      let (header, readEntries, readSuccess) = readHintFile(path)
      check readSuccess == true
      check header.entryCount == 3
      check header.dataFileId == 42
      check readEntries.len == 3

      check readEntries[0].key == "key1"
      check readEntries[0].recordPos == 100
      check readEntries[0].valuePos == 120
      check readEntries[0].valueSize == 10
      check readEntries[0].timestamp == 1000
      check readEntries[0].recordSize == 30

      check readEntries[1].key == "key2"
      check readEntries[2].key == "key3"

  test "Hint file validation - valid file":
    withTestDir("hintfile_validation"):
      let path = testDir / "test.hint"
      let entries = @[
        HintEntry(key: "test", recordPos: 50, valuePos: 60, valueSize: 5, timestamp: 100, recordSize: 20)
      ]

      discard writeHintFile(path, 1, entries)
      check validateHintFile(path) == true

  test "Hint file validation - nonexistent file":
    check validateHintFile("/nonexistent/path.hint") == false

  test "Hint file validation - corrupted magic":
    let testDir = setupTestDir("hint_corrupted")
    defer: cleanupTestDir(testDir)

    let path = testDir / "test.hint"
    discard writeHintFile(path, 1, @[])

    # Corrupt the magic bytes
    let file = open(path, fmReadWriteExisting)
    file.setFilePos(0)
    var badMagic: array[4, char] = ['B', 'A', 'D', '!']
    discard file.writeBuffer(addr badMagic, 4)
    file.close()

    check validateHintFile(path) == false

  test "getHintPath conversion":
    check getHintPath("/data/000001.data") == "/data/000001.hint"
    check getHintPath("test.data") == "test.hint"
    check getHintPath("/path/to/file.data") == "/path/to/file.hint"

  test "hintFileExists":
    let testDir = setupTestDir("hintfile")
    defer: cleanupTestDir(testDir)

    let dataPath = testDir / "000001.data"
    let hintPath = testDir / "000001.hint"

    check hintFileExists(dataPath) == false

    # Create hint file
    discard writeHintFile(hintPath, 1, @[])
    check hintFileExists(dataPath) == true

  test "loadKeyDirFromHint":
    let testDir = setupTestDir("hintfile")
    defer: cleanupTestDir(testDir)

    let path = testDir / "test.hint"
    let entries = @[
      HintEntry(key: "key1", recordPos: 100, valuePos: 120, valueSize: 10, timestamp: 1000, recordSize: 30),
      HintEntry(key: "key2", recordPos: 200, valuePos: 220, valueSize: 20, timestamp: 2000, recordSize: 40)
    ]

    discard writeHintFile(path, 5, entries)

    var keyDir = keydir.init()
    let loaded = loadKeyDirFromHint(path, keyDir)

    check loaded == 2
    check keyDir.len == 2

    let entry1 = keyDir.get("key1")
    check entry1.isSome
    check entry1.get().fileId == 5
    check entry1.get().recordPos == 100
    check entry1.get().valuePos == 120
    check entry1.get().valueSize == 10
    check entry1.get().timestamp == 1000

  test "loadKeyDirFromHint - newer entries win":
    let testDir = setupTestDir("hintfile")
    defer: cleanupTestDir(testDir)

    let path = testDir / "test.hint"
    let entries = @[
      HintEntry(key: "key1", recordPos: 200, valuePos: 220, valueSize: 20, timestamp: 2000, recordSize: 40)
    ]

    discard writeHintFile(path, 5, entries)

    var keyDir = keydir.init()
    # Pre-populate with older entry
    keyDir.add("key1", KeyDirEntry(
      fileId: 1,
      recordPos: 100,
      valuePos: 120,
      valueSize: 10,
      timestamp: 1000,
      recordSize: 30
    ))

    let loaded = loadKeyDirFromHint(path, keyDir)

    check loaded == 1  # Entry was updated

    let entry = keyDir.get("key1")
    check entry.isSome
    check entry.get().timestamp == 2000  # Newer timestamp

  test "loadKeyDirFromHint - older entries ignored":
    let testDir = setupTestDir("hintfile")
    defer: cleanupTestDir(testDir)

    let path = testDir / "test.hint"
    let entries = @[
      HintEntry(key: "key1", recordPos: 100, valuePos: 120, valueSize: 10, timestamp: 1000, recordSize: 30)
    ]

    discard writeHintFile(path, 5, entries)

    var keyDir = keydir.init()
    # Pre-populate with newer entry
    keyDir.add("key1", KeyDirEntry(
      fileId: 1,
      recordPos: 200,
      valuePos: 220,
      valueSize: 20,
      timestamp: 2000,
      recordSize: 40
    ))

    let loaded = loadKeyDirFromHint(path, keyDir)

    check loaded == 0  # No entries updated (hint was older)

    let entry = keyDir.get("key1")
    check entry.isSome
    check entry.get().timestamp == 2000  # Original timestamp preserved

  test "Large hint file":
    let testDir = setupTestDir("hintfile")
    defer: cleanupTestDir(testDir)

    let path = testDir / "large.hint"
    var entries: seq[HintEntry] = @[]

    # Create 1000 entries
    for i in 0..<1000:
      entries.add(HintEntry(
        key: &"key_{i:05d}",
        recordPos: (i * 100).uint64,
        valuePos: (i * 100 + 20).uint64,
        valueSize: 50,
        timestamp: i.int64,
        recordSize: 80
      ))

    let writeSuccess = writeHintFile(path, 1, entries)
    check writeSuccess == true

    let (header, readEntries, readSuccess) = readHintFile(path)
    check readSuccess == true
    check header.entryCount == 1000
    check readEntries.len == 1000

    # Verify some entries
    check readEntries[0].key == "key_00000"
    check readEntries[500].key == "key_00500"
    check readEntries[999].key == "key_00999"
