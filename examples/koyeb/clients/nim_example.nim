#!/usr/bin/env nim
#
# BitBarrel Nim Client Example for Koyeb Deployment
# Demonstrates connecting to BitBarrel on Koyeb with authentication
#

import std/[asyncdispatch, json, strutils, os, options]
import pkg/[websock, websock/websock]


type
  BitBarrelClient* = ref object
    endpoint: string
    token: Option[string]
    ws: Option[WebSock]
    requestId: int


proc newBitBarrelClient*(endpoint: string, token: Option[string] = none(string)): BitBarrelClient =
  ## Create a new BitBarrel client
  BitBarrelClient(
    endpoint: endpoint,
    token: token,
    requestId: 0
  )


proc connect*(self: BitBarrelClient) {.async.} =
  ## Connect to BitBarrel WebSocket endpoint
  var headers: HttpHeaders = newHttpHeaders()

  if self.token.isSome:
    headers["Authorization"] = "Bearer " & self.token.get

  let ws = await websock.createClient(self.endpoint, headers = headers)
  self.ws = some(ws)
  echo "✓ Connected to " & self.endpoint


proc disconnect*(self: BitBarrelClient) {.async.} =
  ## Disconnect from BitBarrel
  if self.ws.isSome:
    await self.ws.get.close()
    echo "✓ Disconnected"


proc set*(self: BitBarrelClient, key, value: string): Future[bool] {.async.} =
  ## Set a key-value pair
  self.requestId.inc

  let request = %*{
    "jsonrpc": "2.0",
    "method": "set",
    "params": [key, value],
    "id": self.requestId
  }

  if self.ws.isNone:
    raise newException(Exception, "Not connected")

  await self.ws.get.sendText($request)
  let response = await self.ws.get.receiveText()
  let result = parseJson(response)

  if result.hasKey("error") and not result["error"].isNil:
    echo fmt"✗ Error setting {key}: {result["error"]}"
    return false

  return true


proc get*(self: BitBarrelClient, key: string): Future[Option[string]] {.async.} =
  ## Get a value by key
  self.requestId.inc

  let request = %*{
    "jsonrpc": "2.0",
    "method": "get",
    "params": [key],
    "id": self.requestId
  }

  if self.ws.isNone:
    raise newException(Exception, "Not connected")

  await self.ws.get.sendText($request)
  let response = await self.ws.get.receiveText()
  let result = parseJson(response)

  if result.hasKey("error") and not result["error"].isNil:
    echo fmt"✗ Error getting {key}: {result["error"]}"
    return none(string)

  if result.hasKey("result") and not result["result"].isNil:
    return some(result["result"].getStr())
  else:
    return none(string)


proc delete*(self: BitBarrelClient, key: string): Future[bool] {.async.} =
  ## Delete a key
  self.requestId.inc

  let request = %*{
    "jsonrpc": "2.0",
    "method": "delete",
    "params": [key],
    "id": self.requestId
  }

  if self.ws.isNone:
    raise newException(Exception, "Not connected")

  await self.ws.get.sendText($request)
  let response = await self.ws.get.receiveText()
  let result = parseJson(response)

  if result.hasKey("error") and not result["error"].isNil:
    echo fmt"✗ Error deleting {key}: {result["error"]}"
    return false

  return true


proc keys*(self: BitBarrelClient, pattern = ""): Future[seq[string]] {.async.} =
  ## Get keys matching pattern
  self.requestId.inc

  let request = %*{
    "jsonrpc": "2.0",
    "method": "keys",
    "params": [pattern],
    "id": self.requestId
  }

  if self.ws.isNone:
    raise newException(Exception, "Not connected")

  await self.ws.get.sendText($request)
  let response = await self.ws.get.receiveText()
  let result = parseJson(response)

  if result.hasKey("error") and not result["error"].isNil:
    echo fmt"✗ Error getting keys: {result["error"]}"
    return @[]

  if result.hasKey("result") and result["result"].kind == JArray:
    var keys: seq[string]
    for key in result["result"]:
      keys.add(key.getStr())
    return keys
  else:
    return @[]


# Demo procedures

proc demoBasicOperations(client: BitBarrelClient) {.async.} =
  ## Demonstrate basic CRUD operations
  echo "\n📦 Basic Operations Demo"
  echo "─" * 40

  # Set some data
  echo "\n1. Setting user data..."
  discard await client.set("user:1001:name", "Alice Smith")
  discard await client.set("user:1001:email", "alice@example.com")
  discard await client.set("user:1001:role", "admin")
  echo "   ✓ User data stored"

  # Read the data
  echo "\n2. Reading user data..."
  let name = await client.get("user:1001:name")
  let email = await client.get("user:1001:email")
  if name.isSome:
    echo fmt"   Name: {name.get}"
  if email.isSome:
    echo fmt"   Email: {email.get}"

  # Update data
  echo "\n3. Updating user's email..."
  discard await client.set("user:1001:email", "alice.smith@example.com")
  let updatedEmail = await client.get("user:1001:email")
  if updatedEmail.isSome:
    echo fmt"   Updated email: {updatedEmail.get}"

  # Delete data
  echo "\n4. Deleting user's role..."
  discard await client.delete("user:1001:role")
  let role = await client.get("user:1001:role")
  echo fmt"   Role after deletion: {role}"


proc demoSessionManagement(client: BitBarrelClient) {.async.} =
  ## Demonstrate session management
  echo "\n🎫 Session Management Demo"
  echo "─" * 40

  let sessionId = "sess_12345"
  let timestamp = int(getTime().toSeconds).int

  echo "\n1. Creating session..."
  discard await client.set(fmt"session:{sessionId}:user_id", "1001")
  discard await client.set(fmt"session:{sessionId}:created_at", $timestamp)
  discard await client.set(fmt"session:{sessionId}:ip", "192.168.1.100")
  echo "   ✓ Session created"

  echo "\n2. Reading session data..."
  let userId = await client.get(fmt"session:{sessionId}:user_id")
  let createdAt = await client.get(fmt"session:{sessionId}:created_at")
  let ip = await client.get(fmt"session:{sessionId}:ip")

  if userId.isSome:
    echo fmt"   User ID: {userId.get}"
  if createdAt.isSome:
    echo fmt"   Created: {createdAt.get}"
  if ip.isSome:
    echo fmt"   IP: {ip.get}"

  echo "\n3. Updating session..."
  discard await client.set(fmt"session:{sessionId}:last_access", $timestamp)
  echo "   ✓ Session updated"

  echo "\n4. Cleaning up session..."
  let keys = await client.keys(fmt"session:{sessionId}:*")
  for key in keys:
    discard await client.delete(key)
  echo fmt"   ✓ Deleted {keys.len} session keys"


proc demoFeatureFlags(client: BitBarrelClient) {.async.} =
  ## Demonstrate feature flag management
  echo "\n🚩 Feature Flags Demo"
  echo "─" * 40

  let features = {
    "new_dashboard": true,
    "dark_mode": true,
    "beta_api": false,
    "experimental_ml": true
  }.toTable

  echo "\n1. Setting feature flags..."
  for feature, enabled in features:
    discard await client.set(fmt"feature:{feature}", $enabled)
    let status = if enabled: "✓" else: "✗"
    echo fmt"   {status} {feature}: {if enabled: \"enabled\" else: \"disabled\"}"

  echo "\n2. Checking feature flags..."
  for feature in features.keys:
    let value = await client.get(fmt"feature:{feature}")
    let enabled = value.isSome and value.get == "true"
    let status = if enabled: "✓" else: "✗"
    echo fmt"   {status} {feature}: {if enabled: \"enabled\" else: \"disabled\"}"


proc demoCounter(client: BitBarrelClient) {.async.} =
  ## Demonstrate counter operations
  echo "\n🧮 Counter Demo"
  echo "─" * 40

  let page = "/home"

  echo "\n1. Page view counter..."
  for i in 1..5:
    let current = await client.get(fmt"pageviews:{page}")
    let count = if current.isSome: parseInt(current.get) else: 0
    discard await client.set(fmt"pageviews:{page}", $(count + 1))
    echo fmt"   View {i}: Total views = {count + 1}"

  echo "\n2. Unique visitors..."
  let visitorId = "user_1001"
  let visitors = await client.get(fmt"visitors:{page}")
  var visitorList: seq[string]
  if visitors.isSome:
    visitorList = visitors.get.parseJson().getElems().map(proc(j: JsonNode): string = j.getStr())
  if visitorId notin visitorList:
    visitorList.add(visitorId)
    discard await client.set(fmt"visitors:{page}", $(%visitorList))
  echo fmt"   ✓ Visitor {visitorId} added"
  echo fmt"   Total unique visitors: {visitorList.len}"


proc demoPerformanceTest(client: BitBarrelClient) {.async.} =
  ## Simple performance test
  echo "\n⚡ Performance Test"
  echo "─" * 40

  echo "\nRunning 100 operations..."
  let startTime = getTime()

  # Mix of writes and reads
  for i in 0..49:
    discard await client.set(fmt"perf:test:{i}", fmt"value_{i}")
    discard await client.get(fmt"perf:test:{i mod 25}")

  let elapsed = getTime() - startTime
  let opsPerSec = 100.0 / elapsed.inSeconds

  echo fmt"   ✓ Completed 100 operations in {elapsed.inMicroseconds / 1000:.3f}ms"
  echo fmt"   ✓ Throughput: {opsPerSec:.0f} ops/sec"

  # Cleanup
  let keys = await client.keys("perf:test:*")
  for key in keys:
    discard await client.delete(key)
  echo fmt"   ✓ Cleaned up {keys.len} test keys"


proc demoErrorHandling(client: BitBarrelClient) {.async.} =
  ## Demonstrate error handling
  echo "\n⚠️  Error Handling Demo"
  echo "─" * 40

  echo "\n1. Getting non-existent key..."
  let result = await client.get("nonexistent:key")
  echo fmt"   Result: {result}"

  echo "\n2. Error handling in Nim..."
  try:
    # This will fail if not connected
    let badClient = newBitBarrelClient("ws://invalid")
    discard await badClient.get("test")
  except:
    echo "   ✓ Exception caught and handled"


proc main() {.async.} =
  ## Main demo procedure
  let koyebEndpoint = getEnv("BITBARREL_ENDPOINT", "wss://my-bitbarrel.koyeb.app")
  let koyebToken = getEnv("BITBARREL_JWT_SECRET")

  echo fmt"Connecting to BitBarrel at {koyebEndpoint}"
  if koyebToken.len > 0:
    echo "Using authentication token"

  # Create client
  let client = newBitBarrelClient(koyebEndpoint, some(koyebToken))

  try:
    # Connect
    await client.connect()

    # Run demos
    await demoBasicOperations(client)
    await demoSessionManagement(client)
    await demoFeatureFlags(client)
    await demoCounter(client)
    await demoPerformanceTest(client)
    await demoErrorHandling(client)

    # List all keys we created
    echo "\n📋 Final Key Listing"
    echo "─" * 40
    let keys = await client.keys("")
    echo fmt"\nTotal keys in database: {keys.len}"
    for key in keys.sorted:
      echo fmt"   - {key}"

  except Exception as e:
    echo fmt"\n✗ Error: {e.msg}"

  finally:
    # Disconnect
    await client.disconnect()

  echo "\n✓ Demo completed successfully!"


when isMainModule:
  waitFor main()
