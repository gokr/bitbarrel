## Comprehensive tests for range queries with cursor-based pagination

import std/[unittest, os]
import ../src/bitbarrel/barrel
import ../src/bitbarrel/types
import ../src/storage/critbitindex
import ../src/network/protocol

const TestDir = "test_range_data"

proc cleanup() =
  if dirExists(TestDir):
    removeDir(TestDir)

proc setup() =
  cleanup()
  createDir(TestDir)

suite "CritBitIndex - Range Queries with Cursor Pagination":
  setup:
    setup()

  teardown:
    cleanup()

  test "itemsInRange with simple range":
    var index = critbitindex.init()

    index.add("user:aaa", KeyDirEntry(fileId: 1'u32, recordPos: 100'u64, valuePos: 120'u64, valueSize: 10'u32, timestamp: 1000'i64, recordSize: 50'u32, deleted: false))
    index.add("user:bbb", KeyDirEntry(fileId: 1'u32, recordPos: 150'u64, valuePos: 170'u64, valueSize: 10'u32, timestamp: 1001'i64, recordSize: 50'u32, deleted: false))
    index.add("user:ccc", KeyDirEntry(fileId: 1'u32, recordPos: 200'u64, valuePos: 220'u64, valueSize: 10'u32, timestamp: 1002'i64, recordSize: 50'u32, deleted: false))
    index.add("user:ddd", KeyDirEntry(fileId: 1'u32, recordPos: 250'u64, valuePos: 270'u64, valueSize: 10'u32, timestamp: 1003'i64, recordSize: 50'u32, deleted: false))
    index.add("user:eee", KeyDirEntry(fileId: 1'u32, recordPos: 300'u64, valuePos: 320'u64, valueSize: 10'u32, timestamp: 1004'i64, recordSize: 50'u32, deleted: false))

    let items = index.itemsInRange("user:bbb", "user:fff", 10, "")
    check items.len == 4
    check items[0][0] == "user:bbb"
    check items[1][0] == "user:ccc"
    check items[2][0] == "user:ddd"
    check items[3][0] == "user:eee"

  test "itemsInRange with cursor pagination":
    var index = critbitindex.init()

    # Add keys in sorted order
    for i in 0..<20:
      let key = "user:" & chr(ord('a') + i)
      index.add(key, KeyDirEntry(fileId: 1'u32, recordPos: uint64(100 + i * 50), valuePos: uint64(120 + i * 50), valueSize: 10'u32, timestamp: int64(1000 + i), recordSize: 50'u32, deleted: false))

    let page1 = index.itemsInRange("user:a", "user:z", 5, "")
    check page1.len == 5
    check page1[0][0] == "user:a"
    check page1[4][0] == "user:e"

    let cursor = page1[4][0]
    let page2 = index.itemsInRange("user:a", "user:z", 5, cursor)
    check page2.len == 5
    check page2[0][0] == "user:f"
    check page2[4][0] == "user:j"

  test "itemsWithPrefix with cursor":
    var index = critbitindex.init()

    for i in 0..<10:
      let userKey = "user:" & chr(ord('a') + i)
      let postKey = "post:" & chr(ord('a') + i)
      index.add(userKey, KeyDirEntry(fileId: 1'u32, recordPos: uint64(100 + i * 50), valuePos: uint64(120 + i * 50), valueSize: 10'u32, timestamp: int64(1000 + i), recordSize: 50'u32, deleted: false))
      index.add(postKey, KeyDirEntry(fileId: 1'u32, recordPos: uint64(500 + i * 50), valuePos: uint64(520 + i * 50), valueSize: 10'u32, timestamp: int64(1000 + i), recordSize: 50'u32, deleted: false))

    let users = index.itemsWithPrefix("user:", 3, "")
    check users.len == 3
    check users[0][0] == "user:a"
    check users[1][0] == "user:b"
    check users[2][0] == "user:c"

    let cursor = users[2][0]
    let users2 = index.itemsWithPrefix("user:", 3, cursor)
    check users2.len == 3
    check users2[0][0] == "user:d"
    check users2[2][0] == "user:f"

  test "itemsWithPrefix filters deleted entries":
    var index = critbitindex.init()

    index.add("user:a", KeyDirEntry(fileId: 1'u32, recordPos: 100'u64, valuePos: 120'u64, valueSize: 10'u32, timestamp: 1000'i64, recordSize: 50'u32, deleted: false))
    index.add("user:b", KeyDirEntry(fileId: 1'u32, recordPos: 150'u64, valuePos: 170'u64, valueSize: 10'u32, timestamp: 1001'i64, recordSize: 50'u32, deleted: true))
    index.add("user:c", KeyDirEntry(fileId: 1'u32, recordPos: 200'u64, valuePos: 220'u64, valueSize: 10'u32, timestamp: 1002'i64, recordSize: 50'u32, deleted: false))

    let items = index.itemsWithPrefix("user:", 10, "")
    check items.len == 2
    check items[0][0] == "user:a"
    check items[1][0] == "user:c"

  test "empty range returns nothing":
    var index = critbitindex.init()

    index.add("user:a", KeyDirEntry(fileId: 1'u32, recordPos: 100'u64, valuePos: 120'u64, valueSize: 10'u32, timestamp: 1000'i64, recordSize: 50'u32, deleted: false))

    let items = index.itemsInRange("user:c", "user:f", 10, "")
    check items.len == 0

  test "hasMore detection":
    var index = critbitindex.init()

    for i in 0..<10:
      let key = "user:" & chr(ord('a') + i)
      index.add(key, KeyDirEntry(fileId: 1'u32, recordPos: uint64(100 + i * 50), valuePos: uint64(120 + i * 50), valueSize: 10'u32, timestamp: int64(1000 + i), recordSize: 50'u32, deleted: false))

    let page1 = index.itemsInRange("user:a", "user:z", 10, "")
    check page1.len == 10

suite "Barrel API - Range Queries with Values":
  setup:
    setup()

  teardown:
    cleanup()

  test "itemsInRange returns key-value pairs in CritBit mode":
    var config = defaultBarrelConfig()
    config.mode = bmCritBit
    let barrel = openBarrel(TestDir / "test.db", config)

    check barrel.set("user:aa", "Alice")
    check barrel.set("user:ab", "Bob")
    check barrel.set("user:ac", "Charlie")
    check barrel.set("user:ad", "David")

    let (items, cursor, hasMore) = barrel.itemsInRange("user:ab", "user:ae", 10, "")
    check items.len == 3
    check items[0] == ("user:ab", "Bob")
    check items[1] == ("user:ac", "Charlie")
    check items[2] == ("user:ad", "David")
    check hasMore == false

    barrel.close()

  test "itemsInRange with cursor pagination":
    var config = defaultBarrelConfig()
    config.mode = bmCritBit
    let barrel = openBarrel(TestDir / "test.db", config)

    for i in 0..9:
      let key = "user:" & chr(ord('a') + i)
      check barrel.set(key, "User" & $(i))

    let (page1, cursor1, hasMore1) = barrel.itemsInRange("user:a", "user:aaaz", 3, "")
    check page1.len == 3
    check page1[0] == ("user:a", "User0")
    check page1[2] == ("user:c", "User2")
    check hasMore1 == true

    let (page2, cursor2, hasMore2) = barrel.itemsInRange("user:a", "user:aaaz", 3, cursor1)
    check page2.len == 3
    check page2[0] == ("user:d", "User3")
    check page2[2] == ("user:f", "User5")
    check hasMore2 == true

    let (page3, cursor3, hasMore3) = barrel.itemsInRange("user:a", "user:aaaz", 3, cursor2)
    check page3.len == 3
    check page3[0] == ("user:g", "User6")
    check page3[2] == ("user:i", "User8")
    check hasMore3 == true

    let (page4, cursor4, hasMore4) = barrel.itemsInRange("user:a", "user:aaaz", 3, cursor3)
    check page4.len == 1
    check page4[0] == ("user:j", "User9")
    check hasMore4 == false

    barrel.close()

  test "itemsWithPrefix filters by prefix":
    var config = defaultBarrelConfig()
    config.mode = bmCritBit
    let barrel = openBarrel(TestDir / "test.db", config)

    check barrel.set("user:aa", "Alice")
    check barrel.set("user:ab", "Bob")
    check barrel.set("post:aa", "Post by Alice")
    check barrel.set("post:ab", "Post by Bob")

    let (users, _, _) = barrel.itemsWithPrefix("user:", 10, "")
    check users.len == 2
    check users[0] == ("user:aa", "Alice")
    check users[1] == ("user:ab", "Bob")

    let (posts, _, _) = barrel.itemsWithPrefix("post:", 10, "")
    check posts.len == 2
    check posts[0] == ("post:aa", "Post by Alice")
    check posts[1] == ("post:ab", "Post by Bob")

    barrel.close()

  test "itemsInRange skips deleted entries":
    var config = defaultBarrelConfig()
    config.mode = bmCritBit
    let barrel = openBarrel(TestDir / "test.db", config)

    check barrel.set("user:a", "One")
    check barrel.set("user:b", "Two")
    check barrel.set("user:c", "Three")

    check barrel.delete("user:b")

    let (items, _, _) = barrel.itemsInRange("user:a", "user:d", 10, "")
    check items.len == 2
    check items[0] == ("user:a", "One")
    check items[1] == ("user:c", "Three")

    barrel.close()

  test "itemsInRange requires bmCritBit mode":
    var config = defaultBarrelConfig()
    config.mode = bmHash
    let barrel = openBarrel(TestDir / "test.db", config)

    check barrel.set("user:a", "One")
    check barrel.set("user:b", "Two")

    expect ValueError:
      let _ = barrel.itemsInRange("user:a", "user:c", 10, "")

    barrel.close()

  test "iterator itemsInRange":
    var config = defaultBarrelConfig()
    config.mode = bmCritBit
    let barrel = openBarrel(TestDir / "test.db", config)

    check barrel.set("user:a", "One")
    check barrel.set("user:b", "Two")
    check barrel.set("user:c", "Three")

    var collected: seq[(string, string)]
    for (key, value) in barrel.itemsInRange("user:a", "user:d"):
      collected.add((key, value))

    check collected.len == 3
    check collected[0] == ("user:a", "One")
    check collected[1] == ("user:b", "Two")
    check collected[2] == ("user:c", "Three")

    barrel.close()

  test "iterator itemsWithPrefix":
    var config = defaultBarrelConfig()
    config.mode = bmCritBit
    let barrel = openBarrel(TestDir / "test.db", config)

    check barrel.set("user:a", "One")
    check barrel.set("user:b", "Two")
    check barrel.set("post:a", "Post One")

    var users: seq[(string, string)]
    for (key, value) in barrel.itemsWithPrefix("user:"):
      users.add((key, value))

    check users.len == 2
    check users[0] == ("user:a", "One")
    check users[1] == ("user:b", "Two")

    barrel.close()

suite "Protocol - Range Query Encoding/Decoding":
  setup:
    setup()

  teardown:
    cleanup()

  test "RangeRequest encode/decode roundtrip":
    let original = RangeRequest(
      startKey: "user:aaa",
      endKey: "user:zzz",
      limit: 50,
      cursor: "user:fff"
    )

    let encoded = encodeRangeRequest(original)
    let decoded = decodeRangeRequest(encoded)

    check decoded.startKey == original.startKey
    check decoded.endKey == original.endKey
    check decoded.limit == original.limit
    check decoded.cursor == original.cursor

  test "PrefixRequest encode/decode roundtrip":
    let original = PrefixRequest(
      prefix: "user:",
      limit: 100,
      cursor: "user:zz"
    )

    let encoded = encodePrefixRequest(original)
    let decoded = decodePrefixRequest(encoded)

    check decoded.prefix == original.prefix
    check decoded.limit == original.limit
    check decoded.cursor == original.cursor

  test "RangeResponse encode/decode with multiple items":
    let original = RangeResponse(
      items: @[
        ("user:aa", "Alice"),
        ("user:ab", "Bob"),
        ("user:ac", "Charlie")
      ],
      nextCursor: "user:ac",
      hasMore: true
    )

    let encoded = encodeRangeResponse(original)
    let decoded = decodeRangeResponse(encoded)

    check decoded.items.len == 3
    check decoded.items[0] == ("user:aa", "Alice")
    check decoded.items[1] == ("user:ab", "Bob")
    check decoded.items[2] == ("user:ac", "Charlie")
    check decoded.nextCursor == "user:ac"
    check decoded.hasMore == true

  test "RangeResponse with empty items":
    let original = RangeResponse(
      items: @[],
      nextCursor: "",
      hasMore: false
    )

    let encoded = encodeRangeResponse(original)
    let decoded = decodeRangeResponse(encoded)

    check decoded.items.len == 0
    check decoded.nextCursor == ""
    check decoded.hasMore == false

  test "RangeRequest with empty strings":
    let original = RangeRequest(
      startKey: "",
      endKey: "",
      limit: 0,
      cursor: ""
    )

    let encoded = encodeRangeRequest(original)
    let decoded = decodeRangeRequest(encoded)

    check decoded.startKey == ""
    check decoded.endKey == ""
    check decoded.limit == 0
    check decoded.cursor == ""