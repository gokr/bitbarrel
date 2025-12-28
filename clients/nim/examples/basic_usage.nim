## Basic Usage Example
##
## Demonstrates basic BitBarrel client operations:
## - Connecting to a server
## - Creating and using barrels
## - Setting and getting values
## - Deleting keys
##
## Run:
##   nim c -r examples/basic_usage.nim

import ../src/bitbarrel_client

proc main() =
  echo "BitBarrel Client - Basic Usage Example"
  echo "======================================="

  # Create a client and connect
  var client = newClient("localhost", 9876.Port)

  try:
    echo "\n1. Connecting to server..."
    client.connect()
    echo "   Connected!"

    # Create a barrel
    echo "\n2. Creating barrel 'example_db'..."
    if client.createBarrel("example_db"):
      echo "   Barrel created!"
    else:
      echo "   Barrel already exists"

    # Use the barrel
    echo "\n3. Selecting barrel..."
    if client.useBarrel("example_db"):
      echo "   Using barrel 'example_db'"
    else:
      echo "   Failed to select barrel"
      return

    # Set some key-value pairs
    echo "\n4. Setting key-value pairs..."
    discard client.set("user:1", "Alice")
    discard client.set("user:2", "Bob")
    discard client.set("user:3", "Charlie")
    echo "   Set 3 users"

    # Get values
    echo "\n5. Getting values..."
    echo "   user:1 = ", client.get("user:1")
    echo "   user:2 = ", client.get("user:2")
    echo "   user:3 = ", client.get("user:3")

    # Check existence
    echo "\n6. Checking existence..."
    echo "   user:1 exists: ", client.exists("user:1")
    echo "   user:99 exists: ", client.exists("user:99")

    # Count keys
    echo "\n7. Counting keys..."
    echo "   Total keys: ", client.count()

    # List keys
    echo "\n8. Listing all keys..."
    let keys = client.listKeys()
    for key in keys:
      echo "   - ", key

    # Delete a key
    echo "\n9. Deleting user:2..."
    discard client.delete("user:2")
    echo "   user:2 exists after delete: ", client.exists("user:2")

    # Get or default
    echo "\n10. Using getOrDefault..."
    echo "   user:1 = ", client.getOrDefault("user:1", "unknown")
    echo "   user:99 = ", client.getOrDefault("user:99", "unknown")

    # Ping
    echo "\n11. Pinging server..."
    if client.ping():
      echo "   Server responded: pong"

    # Close barrel
    echo "\n12. Closing barrel..."
    discard client.closeBarrel()
    echo "   Barrel closed"

    # List barrels
    echo "\n13. Listing all barrels..."
    let barrels = client.listBarrels()
    for barrel in barrels:
      echo "   - ", barrel

    # Cleanup (optional)
    echo "\n14. Cleaning up (dropping barrel)..."
    discard client.dropBarrel("example_db")
    echo "   Barrel dropped"

  except ClientError as e:
    echo "Error: ", e.msg

  finally:
    client.close()
    echo "\nConnection closed."

when isMainModule:
  main()
