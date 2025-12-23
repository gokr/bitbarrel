import unittest
import std/[net, random, strutils]
import ../src/network/client

# Test client that assumes server is already running on 127.0.0.1:8081
# This version doesn't start a server thread, avoiding the ORC crash

suite "BitBarrel Client Tests (external server)":
  setup:
    # No setup needed - server runs externally
    discard

  teardown:
    # No teardown needed - server managed externally
    discard

  test "Basic connection to server":
    var client = newClient("localhost", Port(8081))

    client.connect()
    check client.connected

    check client.ping()

    client.close()

  test "Barrel management operations":
    var client = newClient("localhost", Port(8081))
    client.connect()
    defer: client.close()

    let barrelName = "test_barrel_" & $rand(10000)
    check client.createBarrel(barrelName)

    let barrels = client.listBarrels()
    check barrelName in barrels

    check client.openBarrel(barrelName)

    check client.useBarrel(barrelName)
    check client.currentBarrel == barrelName

  test "Key-value operations":
    var client = newClient("localhost", Port(8081))
    client.connect()
    defer: client.close()

    let barrelName = "kv_test_" & $rand(10000)
    check client.createBarrel(barrelName)
    check client.openBarrel(barrelName)
    check client.useBarrel(barrelName)

    check client.set("test_key", "test_value")

    let value = client.get("test_key")
    check value == "test_value"

    check client.exists("test_key")
    check not client.exists("nonexistent_key")

    check client.delete("test_key")
    check not client.exists("test_key")

  test "Unicode and binary data":
    var client = newClient("localhost", Port(8081))
    client.connect()
    defer: client.close()

    let barrelName = "unicode_test_" & $rand(10000)
    check client.createBarrel(barrelName)
    check client.openBarrel(barrelName)
    check client.useBarrel(barrelName)

    let unicodeKey = "测试_key_" & $rand(1000)
    let unicodeValue = "测试_value_" & $rand(1000)

    check client.set(unicodeKey, unicodeValue)
    check client.get(unicodeKey) == unicodeValue

    let binaryValue = "binary\0data\1with\2nulls"
    check client.set("binary_key", binaryValue)
    check client.get("binary_key") == binaryValue

  test "Error handling":
    var client = newClient("localhost", Port(8081))

    try:
      discard client.get("any_key")
      check false
    except CatchableError:
      check true

    client.connect()
    defer: client.close()

    try:
      discard client.get("any_key")
      check false
    except CatchableError:
      check true

    check not client.openBarrel("nonexistent_barrel_" & $rand(10000))

when isMainModule:
  echo "Running BitBarrel client network tests (external server on localhost:8081)..."
