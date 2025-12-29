## Client Tests for BitBarrel Client
##
## Unit tests run without a server.
## Integration tests require a running BitBarrel server and -d:integration flag.
##
## Run unit tests:
##   nim c -r tests/test_client.nim
##
## Run integration tests:
##   nim c -r -d:integration tests/test_client.nim

import std/[unittest, net, strformat, times, random, strutils]
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

# Integration tests - only run with -d:integration
when defined(integration):
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
      client.connect()

      let name = uniqueBarrelName("test_create")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)

    test "create barrel duplicate":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()
      client.connect()

      let name = uniqueBarrelName("test_dup")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check not client.createBarrel(name)  # Duplicate should fail

    test "use barrel":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()
      client.connect()

      let name = uniqueBarrelName("test_use")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)
      check client.currentBarrel == name

    test "use non-existent barrel":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()
      client.connect()

      check not client.useBarrel("nonexistent_barrel_xyz")

    test "list barrels":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()
      client.connect()

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
      client.connect()

      let name = uniqueBarrelName("test_drop")
      check client.createBarrel(name)
      check client.dropBarrel(name)

      # Should not be in list anymore
      let barrels = client.listBarrels()
      check name notin barrels

    test "close barrel":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()
      client.connect()

      let name = uniqueBarrelName("test_close")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)
      check client.currentBarrel == name

      check client.closeBarrel()
      check client.currentBarrel == ""

  suite "Integration: Key-Value Operations":
    test "set and get":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()
      client.connect()

      let name = uniqueBarrelName("test_setget")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)

      check client.set("key1", "value1")
      check client.get("key1") == "value1"

    test "get not found":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()
      client.connect()

      let name = uniqueBarrelName("test_notfound")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)

      expect ClientError:
        discard client.get("nonexistent_key")

    test "get or default":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()
      client.connect()

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
      client.connect()

      expect ClientError:
        discard client.set("key", "value")

    test "delete":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()
      client.connect()

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
      client.connect()

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
      client.connect()

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
      client.connect()

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
      client.connect()

      check client.ping()

    test "large value":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()
      client.connect()

      let name = uniqueBarrelName("test_large")
      defer: discard client.dropBarrel(name)

      check client.createBarrel(name)
      check client.useBarrel(name)

      # 100KB value
      let largeValue = "x".repeat(100 * 1024)
      check client.set("large_key", largeValue)
      check client.get("large_key") == largeValue

  suite "Integration: Concurrency":
    test "sequential operations":
      var client = newClient(TestServerHost, TestServerPort)
      defer: client.close()
      client.connect()

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
