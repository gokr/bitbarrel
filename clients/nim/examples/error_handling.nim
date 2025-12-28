## Error Handling Example
##
## Demonstrates proper error handling with the BitBarrel client:
## - Connection errors
## - Missing key errors
## - No barrel selected errors
##
## Run:
##   nim c -r examples/error_handling.nim

import ../src/bitbarrel_client

proc demonstrateConnectionError() =
  echo "1. Connection Error Example"
  echo "   Trying to connect to non-existent server..."

  var client = newClient("localhost", 9999.Port)
  try:
    client.connect()
    echo "   Connected (unexpected)"
  except ClientError as e:
    echo "   Caught expected error: ", e.msg
  finally:
    client.close()

proc demonstrateNoBarrelError() =
  echo "\n2. No Barrel Selected Error"
  echo "   Trying to get a key without selecting a barrel..."

  var client = newClient("localhost", 9876.Port)
  try:
    client.connect()
    # Don't select a barrel - go straight to get
    discard client.get("some_key")
    echo "   Got value (unexpected)"
  except ClientError as e:
    echo "   Caught expected error: ", e.msg
  finally:
    client.close()

proc demonstrateKeyNotFoundError() =
  echo "\n3. Key Not Found Error"
  echo "   Trying to get a non-existent key..."

  var client = newClient("localhost", 9876.Port)
  try:
    client.connect()
    discard client.createBarrel("error_test")
    discard client.useBarrel("error_test")

    # Try to get a key that doesn't exist
    discard client.get("nonexistent_key_12345")
    echo "   Got value (unexpected)"
  except ClientError as e:
    echo "   Caught expected error: ", e.msg
  finally:
    discard client.dropBarrel("error_test")
    client.close()

proc demonstrateGracefulRecovery() =
  echo "\n4. Graceful Error Recovery"
  echo "   Using getOrDefault for missing keys..."

  var client = newClient("localhost", 9876.Port)
  try:
    client.connect()
    discard client.createBarrel("recovery_test")
    discard client.useBarrel("recovery_test")

    # Set one key
    discard client.set("exists", "I exist!")

    # Use getOrDefault - no exception
    let val1 = client.getOrDefault("exists", "default")
    let val2 = client.getOrDefault("missing", "default")

    echo "   exists = '", val1, "'"
    echo "   missing = '", val2, "' (using default)"

  except ClientError as e:
    echo "   Unexpected error: ", e.msg
  finally:
    discard client.dropBarrel("recovery_test")
    client.close()

proc demonstrateMultipleErrors() =
  echo "\n5. Multiple Error Handling Pattern"
  echo "   Wrapping operations in try blocks..."

  var client = newClient("localhost", 9876.Port)
  var barrelCreated = false

  try:
    # Connection might fail
    client.connect()
    echo "   Connected successfully"

    # Barrel creation might fail (already exists)
    if client.createBarrel("multi_test"):
      barrelCreated = true
      echo "   Barrel created"
    else:
      echo "   Barrel already exists, opening..."
      discard client.openBarrel("multi_test")

    if not client.useBarrel("multi_test"):
      raise newException(ClientError, "Failed to select barrel")

    # Operations that might fail
    try:
      discard client.get("maybe_exists")
    except ClientError:
      echo "   Key not found, setting default..."
      discard client.set("maybe_exists", "now it exists")

    echo "   Value: ", client.get("maybe_exists")

  except ClientError as e:
    echo "   Operation failed: ", e.msg
  finally:
    if barrelCreated:
      discard client.dropBarrel("multi_test")
    client.close()
    echo "   Cleanup complete"

proc main() =
  echo "BitBarrel Client - Error Handling Examples"
  echo "==========================================="

  # Run all demonstrations
  demonstrateConnectionError()
  demonstrateNoBarrelError()
  demonstrateKeyNotFoundError()
  demonstrateGracefulRecovery()
  demonstrateMultipleErrors()

  echo "\nAll examples completed!"

when isMainModule:
  main()
