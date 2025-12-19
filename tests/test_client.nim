import unittest
import std/[os, tempfiles, random, tables, strutils]
import mummy
import ../src/network/[client, server]
import ../src/bitbarrel/types

# Helper to generate test data
proc generateTestData(count: int): Table[string, string] =
  result = initTable[string, string]()
  for i in 0..<count:
    result["key" & $i] = "value" & $i

# Use port 8081 for testing (avoid conflicts with production)
let testPort = Port(8081)

# Global test server (required for threading)
var testServer: BitBarrelServer
var serverThread: Thread[void]
var testDataDir: string

proc serverThreadProc() {.thread.} =
  {.gcsafe.}:
    testServer.start()

proc setupTestServer(): BitBarrelServer =
  testDataDir = getTempDir() / "bitbarrel_test_" & $rand(1000000)
  createDir(testDataDir)

  let config = ServerConfig(
    address: "127.0.0.1",
    port: testPort,
    dataDir: testDataDir,
    workerThreads: 2
  )

  testServer = newServer(config)
  createThread(serverThread, serverThreadProc)
  # Wait for server to be ready
  sleep(100)
  result = testServer

proc teardownTestServer(server: var BitBarrelServer) =
  server.stop()
  joinThread(serverThread)
  # Clean up test data
  removeDir(testDataDir, true)

suite "BitBarrel Client Tests":
  var server: BitBarrelServer

  setup:
    server = setupTestServer()
    # Additional wait to ensure server is fully ready
    sleep(200)

  teardown:
    teardownTestServer(server)

  test "Basic connection to server":
    var client = newClient("localhost", Port(8081))

    # Should connect successfully
    client.connect()
    check client.conn != nil
    check client.conn.connected

    # Ping server
    check client.ping()

    client.close()

  test "Barrel management operations":
    var client = newClient("localhost", Port(8081))
    client.connect()
    defer: client.close()

    # Create barrel
    let barrelName = "test_barrel_" & $rand(10000)
    check client.createBarrel(barrelName)

    # List barrels - should include our new barrel
    let barrels = client.listBarrels()
    check barrelName in barrels

    # Open barrel
    check client.openBarrel(barrelName)

    # Use barrel (set as current)
    check client.useBarrel(barrelName)
    check client.currentBarrel == barrelName

    # Close barrel
    # Note: closeBarrel() operation removes active barrel but doesn't delete it
    # (implementation might vary)

    # Drop barrel (delete it)
    check client.openBarrel(barrelName)  # Need to re-open before drop
    check client.useBarrel(barrelName)
    # Note: Implementation of dropBarrel might need client to have current barrel

    # Verify barrel is gone (list shouldn't include it)
    let finalBarrels = client.listBarrels()
    check barrelName notin finalBarrels

  test "Key-value operations":
    var client = newClient("localhost", Port(8081))
    client.connect()
    defer: client.close()

    # Create and use a barrel
    let barrelName = "kv_test_" & $rand(10000)
    check client.createBarrel(barrelName)
    check client.useBarrel(barrelName)

    # SET operation
    check client.set("test_key", "test_value")

    # GET operation
    let value = client.get("test_key")
    check value == "test_value"

    # EXISTS operation
    check client.exists("test_key")
    check not client.exists("nonexistent_key")

    # DELETE operation
    check client.delete("test_key")
    check not client.exists("test_key")

    # GET non-existent should raise exception
    try:
      discard client.get("test_key")
      check false  # Should not reach here
    except:
      check true  # Expected to raise

  test "Unicode and binary data":
    var client = newClient("localhost", Port(8081))
    client.connect()
    defer: client.close()

    let barrelName = "unicode_test_" & $rand(10000)
    check client.createBarrel(barrelName)
    check client.useBarrel(barrelName)

    # Test unicode data
    let unicodeKey = "测试_key_" & $rand(1000)
    let unicodeValue = "测试_value_" & $rand(1000)

    check client.set(unicodeKey, unicodeValue)
    check client.get(unicodeKey) == unicodeValue

    # Test binary data (simple case)
    let binaryValue = "binary\0data\1with\2nulls"
    check client.set("binary_key", binaryValue)
    check client.get("binary_key") == binaryValue

  test "Error handling":
    var client = newClient("localhost", Port(8081))

    # Operations without connection should fail
    try:
      discard client.get("any_key")
      check false
    except:
      check true

    client.connect()
    defer: client.close()

    # Operations without selecting barrel should fail
    try:
      discard client.get("any_key")
      check false
    except:
      check true

    # Connect to non-existent barrel
    check not client.openBarrel("nonexistent_barrel_" & $rand(10000))

  test "Multiple clients and concurrent operations":
    # Test multiple clients can connect and work independently
    var client1 = newClient("localhost", Port(8081))
    var client2 = newClient("localhost", Port(8081))

    client1.connect()
    client2.connect()
    defer:
      client1.close()
      client2.close()

    # Each client creates their own barrel
    let barrel1 = "client1_test_" & $rand(10000)
    let barrel2 = "client2_test_" & $rand(10000)

    check client1.createBarrel(barrel1)
    check client1.useBarrel(barrel1)
    check client2.createBarrel(barrel2)
    check client2.useBarrel(barrel2)

    # Both should be able to operate independently
    check client1.set("shared_key", "value1")
    check client2.set("shared_key", "value2")

    check client1.get("shared_key") == "value1"
    check client2.get("shared_key") == "value2"

    # List should show both barrels
    let allBarrels = client1.listBarrels()
    check barrel1 in allBarrels
    check barrel2 in allBarrels

  test "Large data handling":
    var client = newClient("localhost", Port(8081))
    client.connect()
    defer: client.close()

    let barrelName = "large_data_test_" & $rand(10000)
    check client.createBarrel(barrelName)
    check client.useBarrel(barrelName)

    # Test with moderately large key (close to limit but not exceeding)
    let largeKey = "k".repeat(1000)  # 1KB key
    let largeValue = "v".repeat(10000)  # 10KB value

    check client.set(largeKey, largeValue)
    check client.get(largeKey) == largeValue

    # Test with many keys
    let testData = generateTestData(100)  # 100 test key-value pairs
    for k, v in testData:
      check client.set(k, v)

    # Verify all
    for k, v in testData:
      check client.get(k) == v

when isMainModule:
  # Run all tests
  echo "Running BitBarrel client network tests..."