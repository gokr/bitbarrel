## BitBarrel Network Client - Barrel Management Example
#
# This example demonstrates managing multiple barrels in BitBarrel.
#
# Prerequisites:
#   - BitBarrel server running: nimble server
#
# Usage:
#   nim c -r --path:src examples/network/barrels.nim

import std/[strformat, tables]
import bitbarrel/client

proc main() =
  echo "=== BitBarrel Network Client - Barrel Management ==="

  var client = newClient("localhost", 9876.Port)

  # Connect to server
  try:
    client.connect()
    echo "✓ Connected to server"
  except ClientError as e:
    echo fmt"✗ Connection failed: {e.msg}"
    quit(1)

  # Create multiple barrels for different purposes
  let barrelNames = @["users", "products", "orders", "cache", "logs", "sessions"]

  echo "\n--- Creating Barrels ---"
  for barrel in barrelNames:
    try:
      discard client.createBarrel(barrel, "")
      echo fmt"✓ Created barrel: {barrel}"
    except ClientError as e:
      if e.msg.contains("already exists"):
        echo fmt"⚠ Barrel '{barrel}' already exists (skipping)"
      else:
        echo fmt"✗ Failed to create barrel '{barrel}': {e.msg}"

  # List all barrels
  echo "\n--- Listing All Barrels ---"
  try:
    let barrels = client.listBarrels()
    echo fmt"✓ Found {barrels.len} barrels:"
    for barrel in barrels:
      echo fmt"  - {barrel}"
  except ClientError as e:
    echo fmt"✗ Failed to list barrels: {e.msg}"

  # Use users barrel and add data
  echo "\n--- Working with Users Barrel ---"
  try:
    discard client.useBarrel("users")
    echo "✓ Using barrel: users"

    # Add user data
    let users = {
      "user:alice":   "{\"name\":\"Alice\",\"email\":\"alice@example.com\",\"role\":\"admin\"}",
      "user:bob":     "{\"name\":\"Bob\",\"email\":\"bob@example.com\",\"role\":\"user\"}",
      "user:charlie": "{\"name\":\"Charlie\",\"email\":\"charlie@example.com\",\"role\":\"user\"}" ,
      "user:david":   "{\"name\":\"David\",\"email\":\"david@example.com\",\"role\":\"moderator\"}"
    }.toTable()

    for key, data in users:
      discard client.set(key, data)
      echo fmt"  ✓ Added user: {key}"

    # List users
    let userKeys = client.listKeys()
    echo fmt"  ✓ Total users: {userKeys.len}"

    # Verify a user
    let alice = client.get("user:alice")
    echo fmt"  ✓ Sample user (alice): {alice}"

  except ClientError as e:
    echo fmt"✗ Error in users barrel: {e.msg}"

  # Use products barrel
  echo "\n--- Working with Products Barrel ---"
  try:
    discard client.useBarrel("products")
    echo "✓ Using barrel: products"

    # Add product data
    let products = {
      "product:laptop":  "{\"name\":\"Laptop\",\"price\":999.99,\"stock\":50,\"category\":\"electronics\"}",
      "product:mouse":   "{\"name\":\"Mouse\",\"price\":29.99,\"stock\":200,\"category\":\"electronics\"}",
      "product:keyboard": "{\"name\":\"Keyboard\",\"price\":79.99,\"stock\":100,\"category\":\"electronics\"}",
      "product:monitor": "{\"name\":\"Monitor\",\"price\":299.99,\"stock\":30,\"category\":\"electronics\"}"
    }.toTable()

    for key, data in products:
      discard client.set(key, data)
      echo fmt"  ✓ Added product: {key}"

    echo fmt"  ✓ Total products: {client.count()}"

  except ClientError as e:
    echo fmt"✗ Error in products barrel: {e.msg}"

  # Use orders barrel
  echo "\n--- Working with Orders Barrel ---"
  try:
    discard client.useBarrel("orders")
    echo "✓ Using barrel: orders"

    # Add order data
    let orders = {
      "order:1001": "{\"user\":\"user:alice\",\"products\":[\"product:laptop\"],\"total\":999.99,\"status\":\"completed\"}",
      "order:1002": "{\"user\":\"user:bob\",\"products\":[\"product:mouse\",\"product:keyboard\"],\"total\":109.98,\"status\":\"pending\"}",
      "order:1003": "{\"user\":\"user:charlie\",\"products\":[\"product:monitor\"],\"total\":299.99,\"status\":\"completed\"}"
    }.toTable()

    for key, data in orders:
      discard client.set(key, data)
      echo fmt"  ✓ Added order: {key}"

    echo fmt"  ✓ Total orders: {client.count()}"

  except ClientError as e:
    echo fmt"✗ Error in orders barrel: {e.msg}"

  # Use cache barrel for temporary data
  echo "\n--- Working with Cache Barrel ---"
  try:
    discard client.useBarrel("cache")
    echo "✓ Using barrel: cache"

    # Add cached data
    discard client.set("cache:product_list", "cached_product_data")
    discard client.set("cache:user_session_123", "session_data")
    discard client.set("cache:api_response", "cached_api_data")

    echo "  ✓ Added 3 cached items"
    echo fmt"  ✓ Cache size: {client.count()} items"

    # Simulate cache expiration
    discard client.delete("cache:api_response")
    echo "  ✓ Removed expired cache entry"
    echo fmt"  ✓ Updated cache size: {client.count()} items"

  except ClientError as e:
    echo fmt"✗ Error in cache barrel: {e.msg}"

  # Switch between barrels
  echo "\n--- Switching Between Barrels ---"
  try:
    # Check users count
    discard client.useBarrel("users")
    let userCount = client.count()
    echo fmt"✓ Users barrel has {userCount} entries"

    # Switch to products
    discard client.useBarrel("products")
    let productCount = client.count()
    echo fmt"✓ Products barrel has {productCount} entries"

    # Verify isolation
    discard client.useBarrel("users")
    assert client.count() == userCount, "User count changed unexpectedly!"
    echo fmt"✓ Barrel isolation confirmed - users still has {userCount} entries"

  except ClientError as e:
    echo fmt"✗ Error switching barrels: {e.msg}"
  except AssertionError:
    echo "✗ FATAL: Data isolation violation detected!"

  # Drop a barrel
  echo "\n--- Dropping a Barrel ---"
  try:
    # First verify the barrel exists
    var barrels = client.listBarrels()
    if "sessions" in barrels:
      echo "✓ Sessions barrel exists (contains {client.count()} items)"

      # Drop the barrel
      discard client.dropBarrel("sessions")
      echo "✓ Dropped sessions barrel"

      # Verify it's gone
      barrels = client.listBarrels()
      if "sessions" notin barrels:
        echo "✓ Confirmed: sessions barrel no longer exists"
      else:
        echo "✗ ERROR: sessions barrel still exists"
      end
    else:
      echo "⚠ Sessions barrel does not exist (may have been deleted already)"
    end

  except ClientError as e:
    echo fmt"✗ Error dropping barrel: {e.msg}"

  # Final barrel list
  echo "\n--- Final Barrel Inventory ---"
  try:
    barrels = client.listBarrels()
    echo fmt"✓ Total barrels: {barrels.len}"
    for barrel in barrels:
      discard client.useBarrel(barrel)
      let count = client.count()
      echo fmt"  - {barrel}: {count} items"
  except ClientError as e:
    echo fmt"✗ Failed to get final inventory: {e.msg}"

  # Close connection
  client.close()
  echo "\n✓ Connection closed"
  echo "\n=== Barrel management completed successfully ==="

when isMainModule:
  main()
