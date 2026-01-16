## BitBarrel Network Client - Basic Operations Example
#
# This example demonstrates basic CRUD operations using the BitBarrel
# network client library.
#
# Prerequisites:
#   - BitBarrel server running: nimble server
#
# Usage:
#   nim c -r --path:src examples/network/basic.nim

import std/[json, times, strformat, net]
import network/client

proc main() =
  echo "=== BitBarrel Network Client - Basic Operations ==="

  # Create a client instance
  var client = newClient("localhost", 9876.Port)

  # Connect to the server
  try:
    client.connect()
    echo "✓ Connected to server"
  except ClientError as e:
    echo fmt"✗ Connection failed: {e.msg}"
    echo "  Make sure the server is running: nimble server"
    quit(1)

  # Create a barrel
  try:
    discard client.createBarrel("demo_basic")
    echo "✓ Created barrel: demo_basic"
  except ClientError as e:
    echo fmt"⚠ Failed to create barrel (may already exist): {e.msg}"

  # Use the barrel
  try:
    discard client.useBarrel("demo_basic")
    echo "✓ Using barrel: demo_basic"
  except ClientError as e:
    echo fmt"✗ Failed to use barrel: {e.msg}"
    client.close()
    quit(1)

  # Store some simple string values
  echo "\n--- Storing String Values ---"
  try:
    discard client.set("greeting", "Hello, BitBarrel!")
    echo "✓ Stored: greeting = Hello, BitBarrel!"

    discard client.set("username", "alice")
    echo "✓ Stored: username = alice"

    discard client.set("status", "active")
    echo "✓ Stored: status = active"
  except ClientError as e:
    echo fmt"✗ Failed to store values: {e.msg}"

  # Retrieve string values
  echo "\n--- Retrieving String Values ---"
  try:
    let greeting = client.get("greeting")
    echo fmt"✓ Retrieved: greeting = {greeting}"

    let username = client.get("username")
    echo fmt"✓ Retrieved: username = {username}"

    let status = client.get("status")
    echo fmt"✓ Retrieved: status = {status}"
  except ClientError as e:
    echo fmt"✗ Failed to retrieve values: {e.msg}"

  # Store JSON data
  echo "\n--- Storing JSON Data ---"
  try:
    let user1 = %*{
      "name": "Alice Johnson",
      "email": "alice@example.com",
      "age": 30,
      "active": true
    }
    discard client.set("user:alice", $user1)
    echo "✓ Stored: user:alice (JSON)"

    let user2 = %*{
      "name": "Bob Smith",
      "email": "bob@example.com",
      "age": 25,
      "active": false
    }
    discard client.set("user:bob", $user2)
    echo "✓ Stored: user:bob (JSON)"
  except ClientError as e:
    echo fmt"✗ Failed to store JSON data: {e.msg}"

  # Retrieve and parse JSON data
  echo "\n--- Retrieving and Parsing JSON ---"
  try:
    let aliceJson = client.get("user:alice")
    let aliceData = parseJson(aliceJson)
    echo fmt"✓ Retrieved and parsed: user:alice"
    let name = aliceData["name"].getStr()
    echo fmt"  Name: {name}"
    let email = aliceData["email"].getStr()
    echo fmt"  Email: {email}"
    let age = aliceData["age"].getInt()
    echo fmt"  Age: {age}"
    let active = aliceData["active"].getBool()
    echo fmt"  Active: {active}"
  except ClientError as e:
    echo fmt"✗ Failed to retrieve JSON data: {e.msg}"
  except JsonParsingError as e:
    echo fmt"✗ Failed to parse JSON: {e.msg}"

  # Check existence
  echo "\n--- Checking Key Existence ---"
  try:
    if client.exists("username"):
      echo "✓ Key 'username' exists"
    else:
      echo "✗ Key 'username' not found"

    if client.exists("nonexistent"):
      echo "✗ Key 'nonexistent' should not exist"
    else:
      echo "✓ Key 'nonexistent' does not exist (correct)"
  except ClientError as e:
    echo fmt"✗ Failed to check existence: {e.msg}"

  # Delete a key
  echo "\n--- Deleting Keys ---"
  try:
    discard client.delete("status")
    echo "✓ Deleted key: status"
  except ClientError as e:
    echo fmt"✗ Failed to delete key: {e.msg}"

  # Verify deletion
  try:
    let _ = client.get("status")
    echo "✗ ERROR: Key 'status' should not exist after deletion"
  except ClientError:
    echo "✓ Confirmed: key 'status' was deleted"

  # Health check (ping)
  echo "\n--- Server Health Check ---"
  try:
    if client.ping():
      echo "✓ Server is responding"
    else:
      echo "✗ Server ping failed"
  except ClientError as e:
    echo fmt"✗ Ping failed: {e.msg}"

  # Performance test: Batch operations
  echo "\n--- Performance Test: 1000 SET operations ---"
  let startTime = cpuTime()
  var successCount = 0

  for i in 1..1000:
    try:
      discard client.set(fmt"perf:key{i}", fmt"value_{i}")
      inc successCount
    except ClientError:
      discard

  let duration = cpuTime() - startTime
  let rate = float(successCount) / duration

  echo fmt"✓ Completed {successCount} SET operations"
  echo fmt"✓ Duration: {duration:.3f} seconds"
  echo fmt"✓ Rate: {rate:.0f} ops/sec"

  # Clean up: delete test data
  echo "\n--- Cleanup ---"
  try:
    for i in 1..1000:
      discard client.delete(fmt"perf:key{i}")
    echo "✓ Cleaned up performance test data"
  except ClientError:
    discard

  # Close the connection
  client.close()
  echo "\n✓ Connection closed"
  echo "\n=== All basic operations completed successfully ==="

when isMainModule:
  main()
