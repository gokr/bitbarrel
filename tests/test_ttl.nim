## TTL Tests
import unittest, os, times, strformat

import ../src/bitbarrel/barrel
import ../src/bitbarrel/types
import ../src/storage/record

suite "TTL Tests":
  var testDir: string
  var barrel: Barrel

  setup:
    testDir = "temp_ttl_" & $now()
    createDir(testDir)
    var config = defaultBarrelConfig()
    config.defaultTtl = 0
    config.checkExpirationOnRead = true
    config.deleteExpiredOnRead = false
    barrel = openBarrel(testDir / "test.db", config)

  teardown:
    if barrel != nil:
      barrel.close()
    removeDir(testDir, true)

  test "Encode and decode timestamp without TTL":
    let ts = 1640995200000'i64  # 2022-01-01 00:00:00 UTC in ms
    let encoded = encodeTimestamp(ts, 0)
    let decoded = decodeTimestamp(encoded)

    check decoded.hasExpiration == false
    check decoded.expiration == 0
    check decoded.ts == ts

  test "Encode and decode timestamp with TTL":
    let ts = 1640995200000'i64
    let ttlSeconds = 3600  # 1 hour
    let encoded = encodeTimestamp(ts, ttlSeconds)
    let decoded = decodeTimestamp(encoded)

    check decoded.hasExpiration == true
    check decoded.expiration >= (ts div 1000 + ttlSeconds)
    check decoded.ts == ts

  test "Check expiration":
    let now = getTime().toUnix()

    # Create a timestamp from 20 seconds ago with 10 second TTL
    # This means it expired 10 seconds ago
    let pastTs = (now - 20) * 1000  # 20 seconds ago in ms
    let encoded = encodeTimestamp(pastTs, 10)  # TTL of 10 seconds

    # Should be expired (expiration time = now - 20 + 10 = now - 10)
    check isExpired(encoded) == true

    # Fresh TTL - current time with 1 hour TTL
    let fresh = encodeTimestamp(now * 1000, 3600)
    check isExpired(fresh) == false

  test "Get remaining TTL":
    let now = getTime().toUnix()
    let ts = now * 1000

    # No expiration
    let noExp = encodeTimestamp(ts, 0)
    check getRemainingTtl(noExp) == 0

    # Expired - use past timestamp with short TTL
    let pastTs = (now - 120) * 1000  # 2 minutes ago
    let expired = encodeTimestamp(pastTs, 60)  # 60 second TTL, expired 1 min ago
    check getRemainingTtl(expired) == 0

    # 5 minutes TTL
    let fiveMin = encodeTimestamp(ts, 300)
    let remaining = getRemainingTtl(fiveMin)
    check remaining >= 0
    check remaining <= 300

  test "Set with default TTL":
    var barrelConfig = defaultBarrelConfig()
    barrelConfig.defaultTtl = 60  # 1 minute default
    barrelConfig.checkExpirationOnRead = true

    let testBarrel = openBarrel(testDir / "ttl_default.db", barrelConfig)

    check testBarrel.set("test", "value") == true

    let ttl = testBarrel.getTtl("test")
    check ttl > 0
    check ttl <= 60

    testBarrel.close()

  test "Set with explicit TTL":
    check barrel.set("test1", "value1", 30) == true  # 30 seconds TTL

    let ttl = barrel.getTtl("test1")
    check ttl > 0
    check ttl <= 30

  test "Set with TTL override":
    barrel.config.defaultTtl = 60
    check barrel.set("test2", "value2", 10) == true  # Override with 10 seconds

    let ttl = barrel.getTtl("test2")
    check ttl > 0
    check ttl <= 10

  test "Set TTL for existing key":
    check barrel.set("original", "data") == true
    check barrel.setTtl("original", 45) == true

    let ttl = barrel.getTtl("original")
    check ttl > 0
    check ttl <= 45

  test "Get TTL for non-existent key":
    let ttl = barrel.getTtl("nonexistent")
    check ttl == 0

  test "Get TTL for key without expiration":
    barrel.config.defaultTtl = 0
    check barrel.set("noexpire", "data") == true

    let ttl = barrel.getTtl("noexpire")
    check ttl == 0

  test "Read expired record returns empty":
    barrel.config.checkExpirationOnRead = true
    barrel.config.deleteExpiredOnRead = false

    # Set with very short TTL (3 seconds)
    check barrel.set("short", "data", 3) == true

    # Wait for expiration
    sleep(4000)  # 4 seconds (buffer time)

    # Should return empty
    let value = barrel.get("short")
    check value == ""

    # TTL should be 0 after expiration
    let ttl = barrel.getTtl("short")
    check ttl == 0

  test "Read expired record not deleted when deleteExpiredOnRead=false":
    barrel.config.checkExpirationOnRead = true
    barrel.config.deleteExpiredOnRead = false

    check barrel.set("test", "data", 1) == true
    sleep(2000)

    let value = barrel.get("test")
    check value == ""

    # Record should still exist in index (tombstone not automatically written)
    check barrel.getTtl("test") == 0

  test "Set and get with TTL disabled":
    var ttlBarrel = openBarrel(testDir / "no_ttl.db")

    let success = ttlBarrel.set("key", "value", 60)  # TTL specified but not checked
    check success == true

    let value = ttlBarrel.get("key")
    check value == "value"  # Should still return value

    ttlBarrel.close()

  test "Multiple expiration checks":
    barrel.config.checkExpirationOnRead = true

    # Create multiple keys with different TTLs
    for i in 0..<5:
      let key = "key" & $i
      let value = "value" & $i
      discard barrel.set(key, value, i + 1)  # TTL = 1 to 5 seconds

    sleep(2000)  # Wait 2 seconds

    # Keys with TTL 1 should be expired
    check barrel.get("key0") == ""
    check barrel.getTtl("key0") == 0

    # Keys with TTL > 2 should still exist
    check barrel.get("key2") == "value2"
    check barrel.getTtl("key2") > 0

# Performance test for TTL overhead
suite "TTL Performance":
  var testDir: string
  var barrel: Barrel

  setup:
    testDir = "temp_perf_" & $now()
    createDir(testDir)
    var config = defaultBarrelConfig()
    config.checkExpirationOnRead = true
    barrel = openBarrel(testDir / "perf.db", config)

  teardown:
    if barrel != nil:
      barrel.close()
    removeDir(testDir, true)

  test "TTL encoding/decoding performance":
    let ts = getTime().toUnix() * 1000
    let iterations = 100000

    # Time encoding
    let startEncode = cpuTime()
    for i in 0..<iterations:
      discard encodeTimestamp(ts, i mod 3600)
    let encodeTime = cpuTime() - startEncode

    echo "\nTTL encoding: ", encodeTime, "s for ", iterations, " operations"
    echo "  ", int(iterations.float / encodeTime), " ops/sec"

    # Time decoding
    let encoded = encodeTimestamp(ts, 3600)
    let startDecode = cpuTime()
    for i in 0..<iterations:
      discard decodeTimestamp(encoded)
    let decodeTime = cpuTime() - startDecode

    echo "TTL decoding: ", decodeTime, "s for ", iterations, " operations"
    echo "  ", int(iterations.float / decodeTime), " ops/sec"

  test "TTL read overhead":
    let iterations = 50000

    # Without TTL
    barrel.config.checkExpirationOnRead = false
    for i in 0..<1000:
      let key = "key" & $i
      let value = "value" & $i
      discard barrel.set(key, value)

    let startNoTTL = cpuTime()
    for i in 0..<iterations:
      let idxMod = i mod 1000
      let key = "key" & $idxMod
      discard barrel.get(key)
    let timeNoTTL = cpuTime() - startNoTTL

    # With TTL
    barrel.config.checkExpirationOnRead = true
    let startWithTTL = cpuTime()
    for i in 0..<iterations:
      let idxMod = i mod 1000
      let key = "key" & $idxMod
      discard barrel.get(key)
    let timeWithTTL = cpuTime() - startWithTTL

    echo "\nRead performance:"
    echo "  Without TTL: ", int(iterations.float / timeNoTTL), " ops/sec"
    echo "  With TTL: ", int(iterations.float / timeWithTTL), " ops/sec"
    echo "  Overhead: ", int((timeWithTTL / timeNoTTL - 1) * 100), "%"