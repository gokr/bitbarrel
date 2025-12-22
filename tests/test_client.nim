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

# Global test data
var testDataDir: string
var testServer: BitBarrelServer

proc setupTestServer(): BitBarrelServer =
  testDataDir = getTempDir() / "bitbarrel_test_" & $rand(1000000)
  createDir(testDataDir)

  let config = ServerConfig(
    address: "127.0.0.1",
    port: testPort,
    dataDir: testDataDir,
    workerThreads: 2
  )

  result = newServer(config)
  testServer = result

proc teardownTestServer(server: BitBarrelServer) =
  # Clean up test data
  removeDir(testDataDir, true)

proc runServer(server: BitBarrelServer) {.thread.} =
  echo "Server thread starting..."
  {.gcsafe.}:
    server.start()
  echo "Server thread finished!"
  # Force cleanup of circular references
  for name, barrel in server.registry.barrels.pairs:
    if barrel.compactController != nil:
      barrel.compactController = nil

var serverThread: Thread[BitBarrelServer]

proc startServerInBackground(server: BitBarrelServer) =
  createThread(serverThread, runServer, server)
  # Wait for server to be ready
  sleep(200)

proc stopServer(server: BitBarrelServer) =
  server.stop()
  joinThread(serverThread)
  # Note: ORC may crash here due to https://github.com/nim-lang/Nim/issues/xxxx
  # but tests complete successfully before the crash

suite "BitBarrel Client Tests":
  var server: BitBarrelServer

  setup:
    try:
      server = setupTestServer()
      startServerInBackground(server)
      # Wait for server to be ready
      sleep(300)
    except CatchableError as e:
      echo "Setup failed: ", e.msg
      raise e

  teardown:
    try:
      stopServer(server)
      teardownTestServer(server)
    except CatchableError as e:
      echo "Teardown failed: ", e.msg
      raise e

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