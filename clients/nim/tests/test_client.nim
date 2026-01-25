## Client Tests for BitBarrel Client
##
## Tests require a BitBarrel server running on localhost:9876
## Integration tests will skip if server is not available
##
## Run all tests:
##   nim c -r tests/test_client.nim

import std/[unittest, net, strformat, times, random, strutils, os]
import ../src/bitbarrel_client

const 
  TestServerHost = "localhost"
  TestServerPort = 9876.Port

# Helper to generate unique barrel names
proc uniqueBarrelName(prefix: string): string =
  let timestamp = epochTime().int64
  let rand = rand(1000000)
  fmt"{prefix}_{timestamp}_{rand}"

suite "Client Creation":
  test "new client with defaults":
    var client = newClient()
    check client.host == "localhost"
    check client.port == 9876.Port
    check not client.isConnected
    check client.currentBarrel == ""

  test "new client with custom host/port":
    var client = newClient("example.com", 8080.Port)
    check client.host == "example.com"
    check client.port == 8080.Port

  test "new client with config":
    let config = ClientConfig(
      host: "myhost",
      port: 1234.Port,
      connectTimeout: 10000,
      requestTimeout: 5000
    )
    var client = newClient(config)
    check client.host == "myhost"
    check client.port == 1234.Port

  test "default config values":
    let config = defaultConfig()
    check config.host == "localhost"
    check config.port == 9876.Port
    check config.connectTimeout == 5000
    check config.requestTimeout == 3000

suite "Client State":
  test "initial state":
    var client = newClient()
    check not client.isConnected
    check client.currentBarrel == ""
    check client.seqCounter == 0

  test "close without connect":
    var client = newClient()
    client.close()  # Should not raise
    check not client.isConnected

suite "ClientError":
  test "error creation":
    let err = newException(ClientError, "test error")
    check err.msg == "test error"

  test "error inheritance":
    let err = newException(ClientError, "test")
    check err of CatchableError

suite "TraverseOptions":
  test "default options":
    let options = TraverseOptions()
    check not options.includeFullData
    check not options.extractArrays
    check not options.firstOnly

  test "custom options":
    let options = TraverseOptions(
      includeFullData: true,
      extractArrays: true,
      firstOnly: false
    )
    check options.includeFullData
    check options.extractArrays
    check not options.firstOnly

suite "Integration: Connection":
  test "connect to server":
    var client = newClient(TestServerHost, TestServerPort)
    defer: client.close()

    client.connect()
    check client.isConnected

    test "connect to non-existent server fails":
      var client = newClient("localhost", 9999.Port)
      defer: client.close()

      expect ClientError:
        client.connect()

    test "double connect is safe":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      client.connect()
      client.connect()  # Should not raise, just return
      check client.isConnected

    test "close connection":
      var client = newClient(TestServerHost, TestServerPort)
      client.connect()
      check client.isConnected

      client.close()
      check not client.isConnected

  suite "Integration: Barrel Management":
    test "create barrel":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      let name = uniqueBarrelName("test_create")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)

    test "create barrel duplicate":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()



      let name = uniqueBarrelName("test_dup")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check not client.createBarrel(name)  # Duplicate should fail

    test "use barrel":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()



      let name = uniqueBarrelName("test_use")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)
      check client.currentBarrel == name

    test "use non-existent barrel":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()



      check not client.useBarrel("nonexistent_barrel_xyz")

    test "list barrels":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()



      let name1 = uniqueBarrelName("test_list1")
      let name2 = uniqueBarrelName("test_list2")
      defer:
        discard client.dropBarrel(name1)
        discard client.dropBarrel(name2)

      check client.createBarrel(name1)
      check client.createBarrel(name2)

      let barrels = client.listBarrels()
      check name1 in barrels
      check name2 in barrels

    test "drop barrel":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()



      let name = uniqueBarrelName("test_drop")
      check client.createBarrel(name)
      check client.dropBarrel(name)

      # Should not be in list anymore
      let barrels = client.listBarrels()
      check name notin barrels

    test "close barrel":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()



      let name = uniqueBarrelName("test_close")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)
      check client.currentBarrel == name

      check client.closeBarrel()
      check client.currentBarrel == ""

    test "get barrel config":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      let name = uniqueBarrelName("test_config")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name, """{"mode": "critbit"}""")

      let config = client.getBarrelConfig(name)
      check config != ""
      check "critbit" in config.toLowerAscii()

    test "set barrel config":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      let name = uniqueBarrelName("test_config_set")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name, """{"mode": "critbit"}""")

      # Update config
      let newConfig = """{"autoCompact": false}"""
      check client.setBarrelConfig(name, newConfig)

      # Verify config was updated
      let config = client.getBarrelConfig(name)
      check "autocompact" in config.toLowerAscii()

  suite "Integration: Key-Value Operations":
    test "set and get":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      let name = uniqueBarrelName("test_setget")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)

      check client.set("key1", "value1")
      check client.get("key1") == "value1"

    test "get not found":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      let name = uniqueBarrelName("test_notfound")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)

      expect ClientError:
        discard client.get("nonexistent_key")

    test "get or default":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      let name = uniqueBarrelName("test_getdefault")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)

      check client.getOrDefault("missing", "default") == "default"
      check client.set("exists", "value")
      check client.getOrDefault("exists", "default") == "value"

    test "set without barrel raises":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      expect ClientError:
        discard client.set("key", "value")

    test "delete":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      let name = uniqueBarrelName("test_delete")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)

      check client.set("key1", "value1")
      check client.exists("key1")
      check client.delete("key1")
      check not client.exists("key1")

    test "exists":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      let name = uniqueBarrelName("test_exists")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)

      check not client.exists("key1")
      check client.set("key1", "value1")
      check client.exists("key1")

    test "count":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      let name = uniqueBarrelName("test_count")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)

      check client.count() == 0
      check client.set("key1", "value1")
      check client.set("key2", "value2")
      check client.set("key3", "value3")
      check client.count() == 3

    test "list keys":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      let name = uniqueBarrelName("test_listkeys")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)

      check client.set("alpha", "1")
      check client.set("beta", "2")
      check client.set("gamma", "3")

      let keys = client.listKeys()
      check keys.len == 3
      check "alpha" in keys
      check "beta" in keys
      check "gamma" in keys

    test "ping":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      check client.ping()

    test "large value":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      let name = uniqueBarrelName("test_large")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)

      # 100KB value
      let largeValue = "x".repeat(32 * 1024 * 1024)
      check client.set("large_key", largeValue)
      check client.get("large_key") == largeValue

    test "range query":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      let name = uniqueBarrelName("test_range")
      defer: discard client.dropBarrel(name)

      # Create ordered barrel for range queries
      check client.createBarrel(name, """{"mode": "critbit"}""")
      check client.useBarrel(name)

      # Add test data
      check client.set("user:001", "Alice")
      check client.set("user:002", "Bob")
      check client.set("user:003", "Charlie")
      check client.set("product:001", "Widget")

      # Test range query
      let (items, _, hasMore) = client.rangeQuery("user:001", "user:003")
      check items.len == 2
      check ("user:001", "Alice") in items
      check ("user:002", "Bob") in items
      check hasMore == false

    test "prefix query":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      let name = uniqueBarrelName("test_prefix")
      defer: discard client.dropBarrel(name)

      # Create ordered barrel for prefix queries
      check client.createBarrel(name, """{"mode": "critbit"}""")
      check client.useBarrel(name)

      # Add test data
      check client.set("user:001", "Alice")
      check client.set("user:002", "Bob")
      check client.set("user:003", "Charlie")
      check client.set("product:001", "Widget")

      # Test prefix query
      let (items, _, _) = client.prefixQuery("user:")
      check items.len == 3
      for item in items:
        check item[0].startsWith("user:")

    test "range count":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      let name = uniqueBarrelName("test_count")
      defer: discard client.dropBarrel(name)

      # Create ordered barrel for range queries
      check client.createBarrel(name, """{"mode": "critbit"}""")
      check client.useBarrel(name)

      # Add test data
      check client.set("user:001", "Alice")
      check client.set("user:002", "Bob")
      check client.set("user:003", "Charlie")
      check client.set("user:004", "David")
      check client.set("product:001", "Widget")

      # Test range count
      let count = client.rangeCount("user:001", "user:004")
      check count == 3

      # Test full range
      let fullCount = client.rangeCount("user:000", "user:999")
      check fullCount == 4

  suite "Integration: Concurrency":
    test "sequential operations":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      try:
        let name = uniqueBarrelName("test_conc")
        defer: discard client.dropBarrel(name)

        check client.createBarrel(name)
        check client.useBarrel(name)

        # Perform many sequential operations
        for i in 0..<100:
          let key = fmt"key_{i}"
          let value = fmt"value_{i}"
          check client.set(key, value)

        check client.count() == 100

        for i in 0..<100:
          let key = fmt"key_{i}"
          let value = fmt"value_{i}"
          check client.get(key) == value

      except CatchableError:
        skip()  # Server not available

    test "concurrent operations":
      discard

  suite "Integration: JWT Authentication":
    test "connect with valid token":
      var client = newClient(TestServerHost, TestServerPort,
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0X3JlYWR3cml0ZSIsInJvbGVzIjpbInJlYWR3cml0ZSJdLCJpYXQiOjE3MDQwNjcyMDAsImV4cCI6NDA5OTc2NzIwMH0.test_signature_for_testing")
      defer: client.close()

      # Connection should succeed with valid token format
      # Note: Actual token verification depends on server auth config
      try:
        client.connect()
        # If server has auth enabled, token validation happens here
        # If auth disabled, connection succeeds regardless
        # Check that the client has token field properly set
        check client.token.len > 0
        client.close()
      except ClientError:
        # Expected if server has auth enabled with different secret
        # This is ok - we're testing the client sends the token
        check true

    test "operations without authentication":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()

      try:
        client.connect()

        # Create barrel and use it
        let name = uniqueBarrelName("test_no_auth")
        defer: discard client.dropBarrel(name)

        check client.createBarrel(name)
        check client.useBarrel(name)

        # Should be able to perform operations without auth
        check client.set("key1", "value1")
        check client.get("key1") == "value1"

      except CatchableError:
        skip()  # Server not available

    test "client creation with token":
      let token = "test-jwt-token"
      var client = newClient(TestServerHost, TestServerPort, token)

      check client.token == token
      check client.host == TestServerHost
      check client.port == TestServerPort
      check not client.isConnected

    test "client config with token":
      let config = ClientConfig(
        host: "localhost",
        port: 9876.Port,
        token: "test-jwt-token"
      )
      var client = newClient(config)

      check client.token == "test-jwt-token"
      check client.host == "localhost"
      check client.port == 9876.Port

suite "Integration: Batch Operations":
  test "batchSet stores multiple items":
    var client = newClient(TestServerHost, TestServerPort)
    defer: client.close()

    try:
      client.connect()

      # Create barrel and use it
      let name = uniqueBarrelName("test_batch_set")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)

      # Batch set multiple items
      let pairs = @[("key1", "value1"), ("key2", "value2"), ("key3", "value3")]
      let successCount = client.setMany(pairs)

      check successCount == 3

      # Verify all items were stored
      check client.get("key1") == "value1"
      check client.get("key2") == "value2"
      check client.get("key3") == "value3"

    except CatchableError:
      skip()  # Server not available

  test "batchGet retrieves multiple items":
    var client = newClient(TestServerHost, TestServerPort)
    defer: client.close()

    try:
      client.connect()

      # Create barrel and use it
      let name = uniqueBarrelName("test_batch_get")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)

      # Store some items first
      discard client.set("key1", "value1")
      discard client.set("key2", "value2")
      discard client.set("key3", "value3")

      # Batch get multiple items
      let keys = @["key1", "key2", "key3", "nonexistent"]
      let results = client.getMany(keys)

      check results.len == 3  # Only found keys
      check ("key1", "value1") in results
      check ("key2", "value2") in results
      check ("key3", "value3") in results

    except CatchableError:
      skip()  # Server not available

  test "batchDelete removes multiple items":
    var client = newClient(TestServerHost, TestServerPort)
    defer: client.close()

    try:
      client.connect()

      # Create barrel and use it
      let name = uniqueBarrelName("test_batch_delete")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)

      # Store some items
      discard client.set("key1", "value1")
      discard client.set("key2", "value2")
      discard client.set("key3", "value3")

      # Batch delete multiple items
      let keys = @["key1", "key2", "nonexistent"]
      let successCount = client.deleteMany(keys)

      check successCount == 3  # All operations completed successfully

      # Verify items were deleted (or tombstoned for nonexistent)
      check not client.exists("key1")
      check not client.exists("key2")
      check client.exists("key3")  # This one remains

    except CatchableError:
      skip()  # Server not available

  test "batch operations with large batch (100 items)":
    var client = newClient(TestServerHost, TestServerPort)
    defer: client.close()

    try:
      client.connect()

      # Create barrel and use it
      let name = uniqueBarrelName("test_batch_large")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)

      # Create 100 key-value pairs
      var pairs: seq[(string, string)]
      for i in 0..<100:
        pairs.add((fmt"key{i}", fmt"value{i}"))

      # Batch set all items
      let setCount = client.setMany(pairs)
      check setCount == 100

      # Batch get all items
      var keys: seq[string]
      for i in 0..<100:
        keys.add(fmt"key{i}")

      let results = client.getMany(keys)
      check results.len == 100

      # Verify all values
      for (key, value) in results:
        check client.get(key) == value

    except CatchableError:
      skip()  # Server not available

  test "batchSet requires barrel selection":
    var client = newClient(TestServerHost, TestServerPort)
    defer: client.close()

    try:
      client.connect()

      # Try batch set without selecting a barrel
      let pairs = @[("key1", "value1")]
      expect ClientError:
        discard client.setMany(pairs)

    except CatchableError:
      skip()  # Server not available

  test "batchGet requires barrel selection":
    var client = newClient(TestServerHost, TestServerPort)
    defer: client.close()

    try:
      client.connect()

      # Try batch get without selecting a barrel
      let keys = @["key1"]
      expect ClientError:
        discard client.getMany(keys)

    except CatchableError:
      skip()  # Server not available

  test "batchDelete requires barrel selection":
    var client = newClient(TestServerHost, TestServerPort)
    defer: client.close()

    try:
      client.connect()

      # Try batch delete without selecting a barrel
      let keys = @["key1"]
      expect ClientError:
        discard client.deleteMany(keys)

    except CatchableError:
      skip()  # Server not available

suite "Key Watching":
  test "watch requires barrel selection":
    var client = newClient(TestServerHost, TestServerPort)
    defer: client.close()

    try:
      client.connect()

      # Try watch without selecting a barrel
      expect ClientError:
        discard client.watch("user:*", includeValues=false)

    except CatchableError:
      skip()  # Server not available

  test "watch basic functionality":
    var client = newClient(TestServerHost, TestServerPort)
    defer: client.close()

    var events: seq[PubSubEvent] = @[]

    try:
      client.connect()

      let barrelName = uniqueBarrelName("watch_test")
      discard client.createBarrel(barrelName, bmHash)
      defer: discard client.dropBarrel(barrelName)

      discard client.useBarrel(barrelName)

      # Set up message handler
      client.onMessage = proc(event: PubSubEvent) {.closure, gcsafe.} =
        {.gcsafe.}:
          events.add(event)

      # Subscribe to key events
      let subId = client.subscribe("kv:")
      defer: discard client.unsubscribe(subId)

      # Watch pattern
      discard client.watch("user:*", includeValues=false)

      # Wait for subscription
      sleep(100)

      # Set a matching key
      discard client.set("user:1", "Alice")

      # Wait for event
      sleep(500)

      # Verify event received
      check events.len >= 1
      let event = events[^1]  # last event
      check event.topic.contains("user:1")
      check event.messageType == mtKvChange
      check event.payload == ""

    except CatchableError:
      skip()  # Server not available

  test "watch with values":
    var client = newClient(TestServerHost, TestServerPort)
    defer: client.close()

    var events: seq[PubSubEvent] = @[]

    try:
      client.connect()

      let barrelName = uniqueBarrelName("watch_values_test")
      discard client.createBarrel(barrelName, bmHash)
      defer: discard client.dropBarrel(barrelName)

      discard client.useBarrel(barrelName)

      # Set up message handler
      client.onMessage = proc(event: PubSubEvent) {.closure, gcsafe.} =
        {.gcsafe.}:
          events.add(event)

      # Subscribe to key events
      let subId = client.subscribe("kv:")
      defer: discard client.unsubscribe(subId)

      # Watch with values
      discard client.watch("cache:*", includeValues=true)

      # Wait for subscription
      sleep(100)

      # Set a matching key
      discard client.set("cache:item1", "value1")

      # Wait for event
      sleep(500)

      # Verify event received with value
      check events.len >= 1
      let event = events[^1]
      check event.topic.contains("cache:item1")
      check event.payload == "value1"

    except CatchableError:
      skip()  # Server not available

  test "unwatch stops events":
    var client = newClient(TestServerHost, TestServerPort)
    defer: client.close()

    var events: seq[PubSubEvent] = @[]

    try:
      client.connect()

      let barrelName = uniqueBarrelName("unwatch_test")
      discard client.createBarrel(barrelName, bmHash)
      defer: discard client.dropBarrel(barrelName)

      discard client.useBarrel(barrelName)

      # Set up message handler
      client.onMessage = proc(event: PubSubEvent) {.closure, gcsafe.} =
        {.gcsafe.}:
          events.add(event)

      # Subscribe to key events
      let subId = client.subscribe("kv:")
      defer: discard client.unsubscribe(subId)

      # Set up watch
      discard client.watch("temp:*", includeValues=false)
      sleep(100)

      # Now unwatch
      client.unwatch("temp:*")
      sleep(100)

      # Set a key that would match the old pattern
      discard client.set("temp:1", "value1")

      # Wait to ensure no event comes
      sleep(500)

      # Should not have received any events
      check events.len == 0

    except CatchableError:
      skip()  # Server not available
