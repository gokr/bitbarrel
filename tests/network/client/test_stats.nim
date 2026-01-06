## Tests for cmdGetBarrelStats protocol command

import std/[unittest, os, tables]
import ../../../src/bitbarrel/barrel
import ../../../src/network/protocol
import ../../../src/network/server
import ../../../src/network/auth
import ../../../src/network/session
import mummy

type
  TestEnv = object
    server: BitBarrelServer
    testPath: string

proc setupTestEnv(): TestEnv =
  result.testPath = "test_protocol_stats.db"

  # Clean up if exists
  if fileExists(result.testPath):
    removeFile(result.testPath)

  # Create test data directory
  createDir("./test_data/")

  # Create server with config
  result.server = newServer(ServerConfig(
    address: "127.0.0.1",
    port: Port(0),  # Use any available port
    dataDir: "./test_data/",
    workerThreads: 1,
    auth: AuthConfig()  # Auth disabled
  ))

proc teardownTestEnv(env: var TestEnv) =
  # Clean up
  if fileExists(env.testPath):
    removeFile(env.testPath)
  removeDir("./test_data/")

suite "Protocol Statistics Tests":

  test "BarrelStats JSON encoding/decoding":
    var stats: BarrelStats
    stats.totalKeys = 100
    stats.activeKeys = 90
    stats.deletedKeys = 10
    stats.fileCount = 3
    stats.totalSize = 1048576
    stats.activeFileSize = 524288
    stats.avgKeySize = 8.5
    stats.avgValueSize = 256.0
    stats.avgRecordSize = 264.5
    stats.fragmentationRatio = 0.15
    stats.isCompacting = false
    stats.lastCompactTime = "2026-01-02T10:00:00Z"
    stats.recordsScanned = 1000
    stats.recordsKept = 850
    stats.recordsDropped = 150
    stats.indexMode = "bmHash"
    stats.syncMode = "sync"
    stats.dataPath = "test.db"
    stats.lastModified = "2026-01-02T09:00:00Z"

    # Encode to JSON
    let jsonStr = encodeBarrelStats(stats)
    check jsonStr.len > 0

    # Decode from JSON
    let decoded = decodeBarrelStats(jsonStr)

    # Verify all fields match
    check decoded.totalKeys == stats.totalKeys
    check decoded.activeKeys == stats.activeKeys
    check decoded.deletedKeys == stats.deletedKeys
    check decoded.fileCount == stats.fileCount
    check decoded.totalSize == stats.totalSize
    check decoded.activeFileSize == stats.activeFileSize
    check abs(decoded.avgKeySize - stats.avgKeySize) < 0.001
    check abs(decoded.avgValueSize - stats.avgValueSize) < 0.001
    check abs(decoded.avgRecordSize - stats.avgRecordSize) < 0.001
    check abs(decoded.fragmentationRatio - stats.fragmentationRatio) < 0.001
    check decoded.isCompacting == stats.isCompacting
    check decoded.lastCompactTime == stats.lastCompactTime
    check decoded.recordsScanned == stats.recordsScanned
    check decoded.recordsKept == stats.recordsKept
    check decoded.recordsDropped == stats.recordsDropped
    check decoded.indexMode == stats.indexMode
    check decoded.syncMode == stats.syncMode
    check decoded.dataPath == stats.dataPath
    check decoded.lastModified == stats.lastModified

  test "getStats() on empty barrel":
    var env = setupTestEnv()
    defer: teardownTestEnv(env)

    # Create a barrel
    check env.server.registry.createBarrel("test", defaultBarrelConfig())
    var barrel = env.server.registry.getBarrel("test").get()

    # Get stats
    let stats = barrel.getStats()

    # Verify empty barrel stats
    check stats.totalKeys == 0
    check stats.activeKeys == 0
    check stats.deletedKeys == 0
    check stats.fileCount >= 0
    check stats.totalSize >= 0

  test "getStats() with data":
    var env = setupTestEnv()
    defer: teardownTestEnv(env)

    # Clean up from previous test
    if dirExists("./test_data/"):
      for file in walkFiles("./test_data/test*.data"):
        removeFile(file)

    # Create and open barrel with different name
    check env.server.registry.createBarrel("test2", defaultBarrelConfig())
    var barrel = env.server.registry.getBarrel("test2").get()

    # Add some data
    discard barrel.set("key1", "value1")
    discard barrel.set("key2", "value2")
    discard barrel.set("key3", "value3")
    discard barrel.delete("key2")  # This creates a tombstone

    # Get stats
    let stats = barrel.getStats()

    # Verify stats
    check stats.totalKeys == 3  # 2 active + 1 tombstone
    check stats.activeKeys == 2
    check stats.deletedKeys == 1
    check stats.avgKeySize > 0
    check stats.avgValueSize > 0

  test "Protocol command constant":
    check ord(cmdGetBarrelStats) == 0x18

  test "Command string representation":
    check $cmdGetBarrelStats == "GET_BARREL_STATS"

  test "decodeRequest validates cmdGetBarrelStats":
    # Create a request with cmdGetBarrelStats
    let req = newRequest(cmdGetBarrelStats, seq = 123)
    let encoded = encodeRequest(req)
    let decoded = decodeRequest(encoded)

    check decoded.command == cmdGetBarrelStats
    check decoded.seq == 123

  test "Empty BarrelStats serialization":
    var stats: BarrelStats
    let jsonStr = encodeBarrelStats(stats)
    let decoded = decodeBarrelStats(jsonStr)

    # Verify default values
    check decoded.totalKeys == 0
    check decoded.activeKeys == 0
    check decoded.deletedKeys == 0
    check decoded.fileCount == 0
    check decoded.totalSize == 0
    check decoded.fragmentationRatio == 0.0
    check decoded.isCompacting == false
