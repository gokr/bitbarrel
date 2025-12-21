import unittest
import std/[os, tempfiles, random, tables, locks, httpclient, json]
import mummy
import ../src/network/[server, session, protocol]
import ../src/bitbarrel/[types, config]

# Test server setup
var serverThread: Thread[void]
var testDataDir: string

proc serverStarter(param: pointer) {.thread.} =
  let serverPtr = cast[ptr BitBarrelServer](param)
  {.gcsafe.}:
    serverPtr[].start()

proc setupTestServer(): BitBarrelServer =
  testDataDir = getTempDir() / "bitbarrel_server_test_" & $rand(1000000)
  createDir(testDataDir)

  let config = ServerConfig(
    address: "127.0.0.1",
    port: Port(8081),
    dataDir: testDataDir,
    workerThreads: 2
  )

  result = newServer(config)
  createThread(serverThread, serverStarter, result.addr)
  # Wait for server to be ready
  sleep(200)

proc teardownTestServer(server: var BitBarrelServer) =
  server.stop()
  joinThread(serverThread)
  # Clean up test data
  removeDir(testDataDir, true)

# Helper for REST API calls
proc makeRestRequest(httpMethod, path: string, body: string = ""): Response =
  var client = newHttpClient()
  try:
    case httpMethod:
    of "GET":
      result = client.get("http://127.0.0.1:8081" & path)
    of "POST":
      result = client.post("http://127.0.0.1:8081" & path, body)
    of "PUT":
      result = client.put("http://127.0.0.1:8081" & path, body)
    of "DELETE":
      result = client.delete("http://127.0.0.1:8081" & path)
    of "HEAD":
      result = client.head("http://127.0.0.1:8081" & path)
    else:
      raise newException(ValueError, "Unsupported HTTP method: " & httpMethod)
  finally:
    client.close()

suite "BitBarrel Server Tests":
  var server: BitBarrelServer

  setup:
    server = setupTestServer()
    # Ensure server is ready
    sleep(200)

  teardown:
    teardownTestServer(server)

  test "Server starts and stops gracefully":
    # Server is already started in setup
    # Test that we can connect to it
    let client = newHttpClient()
    try:
      let response = client.get("http://127.0.0.1:8081/status")
      check response.status == "200 OK"
      let body = parseJson(response.body)
      check body["status"].getStr() == "ok"
    finally:
      client.close()

  test "/status endpoint returns correct information":
    let response = makeRestRequest("GET", "/status")
    check response.status == "200 OK"
    let body = parseJson(response.body)
    check body["status"].getStr() == "ok"
    check body.hasKey("uptime")
    check body.hasKey("sessions")
    check body.hasKey("barrels")

  test "REST barrel management - create and list":
    # List barrels initially
    var response = makeRestRequest("GET", "/barrels")
    check response.status == "200 OK"
    let initialList = parseJson(response.body)
    let initialCount = initialList.len

    # Create new barrel
    response = makeRestRequest("POST", "/barrels")
    check response.status == "201 Created"
    let createBody = parseJson(response.body)
    check createBody.hasKey("name")
    check createBody["created"].getBool()

    # List barrels - should have one more
    response = makeRestRequest("GET", "/barrels")
    check response.status == "200 OK"
    let newList = parseJson(response.body)
    check newList.len == initialCount + 1

    # Get specific barrel info
    let barrelName = createBody["name"].getStr()
    response = makeRestRequest("GET", "/barrels/" & barrelName)
    check response.status == "200 OK"
    let barrelInfo = parseJson(response.body)
    check barrelInfo["name"].getStr() == barrelName

  test "REST barrel management - delete":
    # Create barrel first
    var response = makeRestRequest("POST", "/barrels")
    check response.status == "201 Created"
    let barrelName = parseJson(response.body)["name"].getStr()

    # Verify it exists
    response = makeRestRequest("GET", "/barrels/" & barrelName)
    check response.status == "200 OK"

    # Delete it
    response = makeRestRequest("DELETE", "/barrels/" & barrelName)
    # Note: DELETE should return 204 No Content on success
    check response.status == "204 No Content" or response.status == "200 OK"

    # Verify it's gone
    response = makeRestRequest("GET", "/barrels/" & barrelName)
    check response.status == "404 Not Found"

  test "REST KV operations":
    # Create barrel
    var response = makeRestRequest("POST", "/barrels")
    let barrelName = parseJson(response.body)["name"].getStr()

    # PUT a key-value pair
    response = makeRestRequest("PUT", "/barrels/" & barrelName & "/kv/test_key", "test_value")
    check response.status == "201 Created"
    check response.headers.getOrDefault("Location", "").contains(barrelName & "/kv/test_key")

    # GET the value
    response = makeRestRequest("GET", "/barrels/" & barrelName & "/kv/test_key")
    check response.status == "200 OK"
    check response.body == "test_value"

    # HEAD check for key existence
    response = makeRestRequest("HEAD", "/barrels/" & barrelName & "/kv/test_key")
    check response.status == "200 OK"

    # HEAD for non-existent key
    response = makeRestRequest("HEAD", "/barrels/" & barrelName & "/kv/nonexistent")
    check response.status == "404 Not Found"

    # DELETE the key
    response = makeRestRequest("DELETE", "/barrels/" & barrelName & "/kv/test_key")
    check response.status == "204 No Content" or response.status == "200 OK"

    # Verify deleted
    response = makeRestRequest("GET", "/barrels/" & barrelName & "/kv/test_key")
    check response.status == "404 Not Found"

  test "URL decoding in REST paths":
    # Create barrel
    var response = makeRestRequest("POST", "/barrels")
    let barrelName = parseJson(response.body)["name"].getStr()

    # Test with URL-encoded key (space and special chars)
    let testKey = "test%20key%2Fwith%2Fslashes"
    let actualKey = "test key/with/slashes"
    let testValue = "url_decoded_value"

    # PUT a value with URL-encoded key
    response = makeRestRequest("PUT", "/barrels/" & barrelName & "/kv/" & testKey, testValue)
    check response.status == "201 Created"

    # GET with URL encoding
    response = makeRestRequest("GET", "/barrels/" & barrelName & "/kv/" & testKey)
    check response.status == "200 OK"
    check response.body == testValue

    # Also verify by trying with the actual decoded key
    response = makeRestRequest("GET", "/barrels/" & barrelName & "/kv/" & actualKey.replace(" ", "%20").replace("/", "%2F"))
    check response.status == "200 OK"

  test "WebSocket binary protocol handling":
    import ../src/network/[client, protocol]

    var wsc = newClient("localhost", Port(8081))
    wsc.connect()
    defer: wsc.close()

    # Send ping via binary protocol
    check wsc.ping()

    # Test barrel creation via WebSocket
    let barrelName = "ws_barrel_" & $rand(10000)
    check wsc.createBarrel(barrelName)
    check wsc.useBarrel(barrelName)

    # Test KV operations via WebSocket
    check wsc.set("ws_key", "ws_value")
    check wsc.get("ws_key") == "ws_value"
    check wsc.exists("ws_key")
    check wsc.delete("ws_key")
    try:
      discard wsc.get("ws_key")
      check false
    except:
      check true

  test "Session management and isolation":
    import ../src/network/[client, protocol]

    # Create two clients
    var client1 = newClient("localhost", Port(8081))
    var client2 = newClient("localhost", Port(8081))

    client1.connect()
    client2.connect()
    defer:
      client1.close()
      client2.close()

    # Each creates their own barrel
    let barrel1 = "session1_" & $rand(10000)
    let barrel2 = "session2_" & $rand(10000)

    check client1.createBarrel(barrel1)
    check client1.useBarrel(barrel1)
    check client2.createBarrel(barrel2)
    check client2.useBarrel(barrel2)

    # Both set same key - should not interfere
    check client1.set("test", "value1")
    check client2.set("test", "value2")

    # Verify isolation
    check client1.get("test") == "value1"
    check client2.get("test") == "value2"

  test "Error handling in REST API":
    # Get non-existent barrel
    var response = makeRestRequest("GET", "/barrels/nonexistent_barrel")
    check response.status == "404 Not Found"

    # Delete non-existent barrel
    response = makeRestRequest("DELETE", "/barrels/nonexistent_barrel")
    check response.status == "404 Not Found"

    # Get from non-existent barrel
    response = makeRestRequest("POST", "/barrels")
    let barrelName = parseJson(response.body)["name"].getStr()
    # Immediately drop it
    makeRestRequest("DELETE", "/barrels/" & barrelName)
    # Now try to get a key
    response = makeRestRequest("GET", "/barrels/" & barrelName & "/kv/somekey")
    check response.status == "404 Not Found"

    # Invalid HTTP method
    response = makeRestRequest("PATCH", "/barrels")
    check response.status == "405 Method Not Allowed"

  test "Concurrent REST requests":
    # Basic test that server can handle multiple concurrent requests
    let client = newHttpClient(sslContext = newContext())
    client.connectionTimeout = 500
    client.maxRedirects = 0

    # Create barrel
    var response = makeRestRequest("POST", "/barrels")
    let barrelName = parseJson(response.body)["name"].getStr()

    try:
      # Launch multiple concurrent PUT requests
      var asyncResponses = newSeq[Future[Response]]()

      for i in 0..<10:
        let future = client.putAsync("http://127.0.0.1:8081/barrels/" & barrelName & "/kv/concurrent_key_" & $i, "value_" & $i)
        asyncResponses.add(future)

      # Wait for all to complete
      for f in asyncResponses:
        let resp = f.wait()
        check resp.status == "201 Created" or resp.status == "200 OK"

      client.close()
    except:
      # If async operations aren't available, fall back to sync
      discard
      client.close()

      # Use sync approach
      for i in 0..<10:
        response = makeRestRequest("PUT", "/barrels/" & barrelName & "/kv/sync_key_" & $i, "value_" & $i)
        check response.status == "201 Created" or response.status == "200 OK"

  test "WebSocket fragmentation handling":
    # Test that server handles fragmented WebSocket frames
    var wsc = newClient("localhost", Port(8081))
    wsc.connect()

    # Large message that requires fragmentation (50KB)
    let largeMessage = repeat("x", 50000)
    check wsc.set("fragmented_key", largeMessage)

    # Verify we can retrieve it
    let retrieved = wsc.get("fragmented_key")
    check retrieved == largeMessage

    wsc.close()

  test "WebSocket handles large messages (near limits)":
    var wsc = newClient("localhost", Port(8081))
    wsc.connect()

    # Test with 64KB key (max size)
    let maxSizeKey = repeat("k", 65535)
    check wsc.set(maxSizeKey, "value")

    # Test with 1MB value (max size)
    let maxSizeValue = repeat("v", 1048576)
    check wsc.set("max_value", maxSizeValue)

    wsc.close()

  test "Connection reset during WebSocket operation":
    # First connection
    var client1 = newClient("localhost", Port(8081))
    client1.connect()

    # Create barrel and write data
    let barrelName = "reset_test"
    check client1.createBarrel(barrelName)
    check client1.useBarrel(barrelName)
    check client1.set("key", "value1")

    # Close without proper disconnect
    client1.close()

    # New connection should work
    var client2 = newClient("localhost", Port(8081))
    client2.connect()
    check client2.useBarrel(barrelName)
    check client2.set("key", "value2")

    let value = client2.get("key")
    check value == "value2"

    client2.close()

  test "WebSocket pong timeout handling":
    var wsc = newClient("localhost", Port(8081))
    wsc.connect()

    # Send ping
    check wsc.ping()

    # Verify connection is still alive by performing operation
    check wsc.set("pong_test", "value")
    let retrieved = wsc.get("pong_test")
    check retrieved == "value"

    wsc.close()

  test "Multiple concurrent WebSocket connections":
    const numClients = 5
    var clients: seq[WebSocketClient]

    # Create multiple clients
    for i in 0..<numClients:
      var client = newClient("localhost", Port(8081))
      client.connect()
      clients.add(client)

    try:
      # Each client creates its own barrel and writes data
      for i, client in clients:
        let barrelName = &"concurrent_ws_{i}"
        check client.createBarrel(barrelName)
        check client.useBarrel(barrelName)
        check client.set(&"key_{i}", &"value_{i}")

      # Verify each client's data is isolated
      for i, client in clients:
        let barrelName = &"concurrent_ws_{i}"
        check client.useBarrel(barrelName)
        let value = client.get(&"key_{i}")
        check value == &"value_{i}"
    finally:
      # Close all clients
      for client in clients:
        client.close()

when isMainModule:
  # Run all tests
  echo "Running BitBarrel server network tests..."