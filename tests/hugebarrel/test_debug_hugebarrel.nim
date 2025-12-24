## Debug test for range query issue

import std/[unittest, os]
import ../../src/bitbarrel/barrel
import ../../src/bitbarrel/types
import ../../src/storage/critbitindex

const TestDir = "test_debug_data"

proc cleanup() =
  if dirExists(TestDir):
    removeDir(TestDir)

proc setup() =
  cleanup()
  createDir(TestDir)

setup()
var config = defaultBarrelConfig()
config.mode = bmCritBit
let b = openBarrel(TestDir / "test.db", config)

for i in 0..9:
  let key = "user:" & chr(ord('a') + i)
  discard b.set(key, "User" & $(i))

echo "Added 10 keys"
echo "Barrel count: ", b.count()

let (page1, cursor1, hasMore1) = b.itemsInRange("user:a", "user:aaaz", 3, "")
echo "page1.len: ", page1.len
echo "page1 items: ", page1
echo "cursor1: ", cursor1
echo "hasMore1: ", hasMore1

let (page2, cursor2, hasMore2) = b.itemsInRange("user:a", "user:aaaz", 3, cursor1)
echo "page2.len: ", page2.len

b.close()
cleanup()