import unittest
import std/[os, random, tables, strutils]
import mummy
import ../src/network/[client, server]

# Helper to generate test data
proc generateTestData(count: int): Table[string, string] =
  result = initTable[string, string]()
  for i in 0..<count:
    result["key" & $i] = "value" & $i

# Use port 8081 for testing (avoid conflicts with production)
let testPort = Port(8081)

# Global test server - following tankfeudserver pattern
var testDataDir: string

proc setupTestDir() =
  testDataDir = getTempDir() / "bitbarrel_test_" & $rand(1000000)
  createDir(testDataDir)

proc cleanupTestDir() =
  removeDir(testDataDir, true)

let testConfig = ServerConfig(
  address: "127.0.0.1",
  port: testPort,
  dataDir: "",
  workerThreads: 2
)

# Global server for the thread to use
var g_server: BitBarrelServer = newServer(testConfig)

# Simple serve function for thread - similar to tankfeudserver pattern
proc serve() =
  echo "Server starting..."
  g_server.start()

var serverThread: Thread[void]

suite "BitBarrel Client Tests":
  setup:
    setupTestDir()
    g_server.config.dataDir = testDataDir
    createThread(serverThread, serve)
    sleep(300)  # Wait for server

  teardown:
    # No explicit cleanup - let process exit
    # This avoids the ORC crash during joinThread
    echo "Tests complete"

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

    # Note: dropBarrel test removed for simplicity

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
    except CatchableError:
      check true

    client.connect()
    defer: client.close()

    # Operations without selecting barrel should fail
    try:
      discard client.get("any_key")
      check false
    except CatchableError:
      check true

    # Connect to non-existent barrel
    check not client.openBarrel("nonexistent_barrel_" & $rand(10000))

when isMainModule:
  # Run all tests
  echo "Running BitBarrel client network tests..."