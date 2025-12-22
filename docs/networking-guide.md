# BitBarrel Client Library Tutorial and Usage Guide

This guide provides comprehensive documentation for using the BitBarrel network client libraries, with examples in both Nim and Go.

## Table of Contents

1. [Getting Started](#getting-started)
2. [Connection Management](#connection-management)
3. [Barrel Operations](#barrel-operations)
4. [Key-Value Operations](#key-value-operations)
5. [Error Handling](#error-handling)
6. [Advanced Features](#advanced-features)
7. [Performance Tuning](#performance-tuning)
8. [Troubleshooting](#troubleshooting)

## Getting Started

### Prerequisites

**Server Setup:**
```bash
# Start the BitBarrel server
nimble server

# Or run directly
nim c -d:release --mm:orc --threads:on -o:bitbarrel_server src/network/server_main.nim
./bitbarrel_server
```

The server listens on `localhost:9876` by default.

### Nim Client Quick Start

```nim
import network/client

# Create a client instance
var client = newClient("localhost", 9876.Port)

# Connect to the server
try:
  client.connect()
  echo "Connected successfully"
except ClientError as e:
  echo "Failed to connect: " & e.msg
  quit(1)

# Create and use a barrel
discard client.createBarrel("mydatabase")
discard client.useBarrel("mydatabase")

# Store some data
discard client.set("greeting", "Hello, BitBarrel!")

# Retrieve data
let value = client.get("greeting")
echo value  # Output: Hello, BitBarrel!

# Clean up
client.close()
```

### Go Client Quick Start (Future)

```go
package main

import (
    "fmt"
    "log"
    "github.com/yourusername/bitbarrel-go"
)

func main() {
    // Create client
    client := bitbarrel.NewClient("localhost", 9876)

    // Connect
    if err := client.Connect(); err != nil {
        log.Fatal("Failed to connect: ", err)
    }
    defer client.Close()

    // Create barrel
    if err := client.CreateBarrel("mydatabase", ""); err != nil {
        log.Fatal("Failed to create barrel: ", err)
    }

    // Use barrel
    if err := client.UseBarrel("mydatabase"); err != nil {
        log.Fatal("Failed to use barrel: ", err)
    }

    // Store data
    if err := client.Set("greeting", "Hello, BitBarrel!"); err != nil {
        log.Fatal("Failed to set: ", err)
    }

    // Retrieve data
    value, err := client.Get("greeting")
    if err != nil {
        log.Fatal("Failed to get: ", err)
    }
    fmt.Println(value)  // Output: Hello, BitBarrel!
}
```

## Connection Management

### Creating a Client

**Nim:**
```nim
# With default configuration (localhost:9876)
var client = newClient()

# With custom host and port
var client = newClient("192.168.1.100", 9000.Port)

# With full configuration
let config = ClientConfig(
  host: "localhost",
  port: 9876.Port,
  connectTimeout: 5000  # milliseconds
)
var client = newClient(config)
```

### Connecting to the Server

**Nim:**
```nim
# Explicit connection
try:
  client.connect()
  echo "Connected to BitBarrel server"
except ClientError as e:
  echo "Connection failed: " & e.msg
  # Handle error appropriately

# Auto-connect on first operation (default behavior)
# No need to call connect() manually
```

**Connection Parameters:**
- Default timeout: 5 seconds for handshake
- Default host: "localhost"
- Default port: 9876

### Connection Lifecycle

```nim
# Best practice: explicit connection management
var client = newClient("localhost", 9876.Port)

try:
  client.connect()

  # Perform operations
  client.useBarrel("mydb")
  discard client.set("key", "value")

except ClientError as e:
  echo "Error: " & e.msg

finally:
  # Always close the connection
  client.close()
```

### Handling Connection Loss

```nim
proc safeOperation(client: var BitBarrelClient) =
  try:
    # Operation will auto-connect if needed
    let value = client.get("important_key")
    echo "Retrieved: " & value

  except ClientError as e:
    if e.msg.contains("timeout"):
      echo "Operation timed out, server may be overloaded"
    elif e.msg.contains("failed to connect"):
      echo "Connection lost, attempting to reconnect..."
      # Wait and retry
      sleep(1000)
      try:
        client.connect()
        echo "Reconnected successfully"
      except:
        echo "Failed to reconnect"
    else:
      echo "Unexpected error: " & e.msg
```

## Barrel Operations

### Creating a Barrel

```nim
# Create a barrel with default configuration
let success = client.createBarrel("mydatabase")
if not success:
  echo "Failed to create barrel (may already exist)"

# Attempt to create, ignoring if it exists
if not client.createBarrel("mydatabase"):
  echo "Barrel already exists, continuing..."
```

### Opening and Using Barrels

```nim
# Create a barrel first
discard client.createBarrel("users")
discard client.createBarrel("products")

# Switch between barrels
discard client.useBarrel("users")
discard client.set("user:1", "Alice")

discard client.useBarrel("products")
discard client.set("product:1", "Laptop")

discard client.useBarrel("users")
let user = client.get("user:1")  # Returns "Alice"
```

### Listing Available Barrels

```nim
let barrels = client.listBarrels()
echo "Available barrels: "
for barrel in barrels:
  echo "  - " & barrel

// Output:
// Available barrels:
//   - users
//   - products
//   - orders
```

### Dropping a Barrel

```nim
# WARNING: This permanently deletes all data in the barrel!
let success = client.dropBarrel("temp_data")
if success:
  echo "Barrel deleted successfully"
else:
  echo "Failed to delete barrel (may not exist)"
```

### Barrel Configuration (Future)

```nim
# Note: JSON configuration currently ignored
# but reserved for future use
let config = """{
  "max_size": "10GB",
  "compression": true,
  "sync_mode": "buffered"
}"""

discard client.createBarrel("optimized", config)
```

## Key-Value Operations

### Storing Data (SET)

```nim
# Simple string values
discard client.set("username", "alice")
discard client.set("email", "alice@example.com")

# JSON data
let userData = """{"name":"Alice","age":30,"active":true}"""
discard client.set("user:123", userData)

# Binary data (Note: limited to 1MB)
let binaryData = readFile("image.png")
discard client.set("image:logo", binaryData)

# Large text data
let largeText = readFile("document.txt")
discard client.set("doc:report", largeText)
```

### Retrieving Data (GET)

```nim
# Simple retrieval
let username = client.get("username")
echo username  // "alice"

# Handling missing keys
try:
  let value = client.get("nonexistent")
  echo "Found: " & value
except ClientError as e:
  if e.msg.contains("not found"):
    echo "Key does not exist"
  else:
    raise e  // Re-raise unexpected errors

// Safe retrieval with default
proc getOrDefault(client: var BitBarrelClient,
                  key, defaultValue: string): string =
  try:
    result = client.get(key)
  except ClientError:
    result = defaultValue

let value = getOrDefault(client, "missing", "default")
echo value  // "default"
```

### Checking Existence (EXISTS)

```nim
if client.exists("user:123"):
  echo "User exists"
  let userData = client.get("user:123")
else:
  echo "User not found"
```

### Deleting Data (DELETE)

```nim
// Delete a single key
discard client.delete("temp:data")

// Conditional delete
if client.exists("cache:old"):
  discard client.delete("cache:old")
  echo "Cached data removed"
```

### Counting Keys

```nim
let keyCount = client.count()
echo "Total keys in barrel: " & $keyCount
```

### Listing All Keys (Use with Caution)

```nim
# Warning: This returns ALL keys - can be slow for large datasets
let allKeys = client.listKeys()
echo "Found " & $allKeys.len & " keys"

for key in allKeys:
  echo "  - " & key
```

### Batch Operations

```nim
# Store multiple items
let items = {
  "product:1": "Laptop",
  "product:2": "Mouse",
  "product:3": "Keyboard"
}

for key, value in items:
  try:
    discard client.set(key, value)
    echo "Stored: " & key
  except ClientError as e:
    echo "Failed to store " & key & ": " & e.msg

// Retrieve multiple items
var results: Table[string, string]
for key, _ in items:
  try:
    let value = client.get(key)
    results[key] = value
  except ClientError:
    echo "Key not found: " & key
```

## Error Handling

### Common Error Types

```nim
try:
  client.connect()
  discard client.useBarrel("mydb")

  let value = client.get("key")

except ClientError as e:
  case true
  of e.msg.contains("failed to connect"):
    echo "ERROR: Could not connect to server"
    echo "  - Check if server is running"
    echo "  - Check host and port configuration"

  of e.msg.contains("not found"):
    echo "ERROR: Key or resource not found"
    echo "  - Verify the key exists"
    echo "  - Check barrel selection"

  of e.msg.contains("No barrel selected"):
    echo "ERROR: No barrel selected"
    echo "  - Call useBarrel() before operations"

  of e.msg.contains("timeout"):
    echo "ERROR: Operation timed out"
    echo "  - Server may be overloaded"
    echo "  - Check network connectivity"

  else:
    echo "ERROR: " & e.msg
    echo "  - Unexpected error occurred"
```

### Connection Error Recovery

```nim
proc robustSet(client: var BitBarrelClient,
               key, value: string,
               maxRetries = 3): bool =

  for i in 1..maxRetries:
    try:
      discard client.set(key, value)
      return true

    except ClientError as e:
      if e.msg.contains("failed to connect") and i < maxRetries:
        echo "Connection lost, retrying... (attempt " & $i & ")"
        sleep(1000 * i)  # Exponential backoff

        # Attempt to reconnect
        try:
          client.close()
          client.connect()
          discard client.useBarrel("mydb")
        except:
          continue
      else:
        echo "Failed to set " & key & ": " & e.msg
        return false

  return false
```

### Timeout Handling

```nim
proc safeGet(client: var BitBarrelClient,
             key: string,
             timeoutMs: int = 3000): string =
  # Note: Current client has fixed 3s timeout
  # This demonstrates pattern for future enhancements

  let startTime = epochTime()
  try:
    result = client.get(key)
  except ClientError as e:
    let elapsed = int((epochTime() - startTime) * 1000)
    if e.msg.contains("timeout"):
      echo "Operation timed out after " & $elapsed & "ms"
    raise
```

## Advanced Features

### Graph Traversal

```nim
# Store graph data
discard client.set("alice",
  """{"name":"Alice","friends":["bob","charlie"]}""")
discard client.set("bob",
  """{"name":"Bob","friends":["alice","david"]}""")

// Traverse relationships (future feature)
// let results = client.traversePath("alice", "friends->*")
```

### Working with JSON Data

```nim
import json

# Store structured data
let user = %*{
  "name": "Alice",
  "email": "alice@example.com",
  "preferences": {
    "theme": "dark",
    "notifications": true
  }
}
discard client.set("user:alice", $user)

// Retrieve and parse
let userJson = client.get("user:alice")
let userData = parseJson(userJson)
echo "Name: " & userData["name"].getStr()
echo "Theme: " & userData["preferences"]["theme"].getStr()
```

### Binary Data Handling

```nim
# Store binary data (e.g., images, files)
proc storeFile(client: var BitBarrelClient,
               key, filename: string): bool =
  try:
    let data = readFile(filename)
    if data.len > 1024 * 1024:  # 1MB limit
      echo "File too large (max 1MB)"
      return false

    discard client.set(key, data)
    return true
  except IOError as e:
    echo "Failed to read file: " & e.msg
    return false

// Retrieve binary data
proc retrieveFile(client: var BitBarrelClient,
                  key, filename: string): bool =
  try:
    let data = client.get(key)
    writeFile(filename, data)
    return true
  except ClientError as e:
    echo "Failed to retrieve: " & e.msg
    return false
```

### Health Checks and Keepalive

```nim
proc checkHealth(client: var BitBarrelClient): bool =
  try:
    return client.ping()
  except:
    return false

// Periodic health check
while true:
  if checkHealth(client):
    echo "Server is healthy"
  else:
    echo "Server not responding!"
    # Attempt reconnection
    try:
      client.close()
      client.connect()
      discard client.useBarrel("mydb")
      echo "Reconnected successfully"
    except ClientError as e:
      echo "Reconnection failed: " & e.msg

  sleep(30000)  # Check every 30 seconds
```

### Concurrent Operations (Multiple Clients)

```nim
import threadpool

proc worker(id: int) =
  var client = newClient("localhost", 9876.Port)
  client.connect()
  discard client.useBarrel("mydb")

  for i in 1..100:
    let key = "worker" & $id & ":key" & $i
    discard client.set(key, "value" & $i)

  client.close()

// Run multiple concurrent workers
parallel:
  for workerId in 1..10:
    spawn worker(workerId)

echo "All workers completed"
```

## Performance Tuning

### Best Practices

```nim
# 1. Reuse connections
# Good - single connection for multiple operations
var client = newClient()
client.connect()

for item in largeDataset:
  discard client.set(item.key, item.value)

client.close()

# Bad - connection per operation
for item in largeDataset:
  var client = newClient()
  client.connect()
  discard client.set(item.key, item.value)
  client.close()

# 2. Batch operations when possible
# Good - multiple operations in one barrel session
discard client.useBarrel("mydb")
discard client.set("key1", "value1")
discard client.set("key2", "value2")
discard client.set("key3", "value3")

# 3. Handle errors appropriately
try:
  let value = client.get("key")
except ClientError:
  # Have fallback logic
  value = getFromBackup()
```

### Performance Tips

1. **Keep connections alive**: Reuse connections for multiple operations
2. **Batch operations**: Group operations to minimize round trips
3. **Use appropriate barrel names**: Organize data logically
4. **Handle timeouts**: Set appropriate timeouts for your use case
5. **Monitor health**: Implement health checks for production use
6. **Size matters**: Keep values under 1MB; split larger data if needed

### Monitoring and Debugging

```nim
proc monitorOperation(client: var BitBarrelClient,
                      op: proc(),
                      opName: string) =
  let start = epochTime()
  try:
    op()
    let duration = (epochTime() - start) * 1000
    echo fmt"{opName} completed in {duration:.2f}ms"
  except ClientError as e:
    let duration = (epochTime() - start) * 1000
    echo fmt"{opName} failed after {duration:.2f}ms: {e.msg}"

// Usage
monitorOperation(client,
  proc() =
    discard client.set("key", "value"),
  "SET operation")
```

## Troubleshooting

### Common Issues

#### "Failed to connect: OS error:..."
**Problem:** Cannot establish connection to server

**Solutions:**
- Verify server is running: `nimble server`
- Check host and port configuration
- Ensure firewall allows connections
- Try localhost first to rule out network issues

#### "No barrel selected. Call useBarrel() first."
**Problem:** Attempting operation without selecting a barrel

**Solutions:**
```nim
discard client.useBarrel("mydatabase")
# Now operations will work
```

#### "Key not found: ..."
**Problem:** GET operation on non-existent key

**Solutions:**
- Check key spelling
- Verify correct barrel is selected
- Use `exists()` to check before GET
- Implement proper error handling

#### "Response timeout"
**Problem:** Operation taking too long

**Solutions:**
- Check server load
- Verify network connectivity
- Consider splitting large operations
- Check for resource constraints (disk, memory)

### Debug Mode

```nim
# Enable debug output in your application
echo "Connecting to BitBarrel..."
var client = newClient("localhost", 9876.Port)

try:
  client.connect()
  echo "Successfully connected"

  let barrels = client.listBarrels()
  echo "Available barrels: " & $barrels

except ClientError as e:
  echo "ERROR: " & e.msg
  echo "Stack trace: " & getCurrentExceptionMsg()
  quit(1)
```

### Logging Operations

```nim
import logging

# Set up logging
addHandler(newConsoleLogger())
setLogFilter(lvlInfo)

proc loggedSet(client: var BitBarrelClient,
               key, value: string): bool =
  info("Setting " & key & " = " & value)
  let start = epochTime()

  try:
    result = client.set(key, value)
    let duration = (epochTime() - start) * 1000
    info("Set completed in " & $duration & "ms")
  except ClientError as e:
    let duration = (epochTime() - start) * 1000
    error("Set failed after " & $duration & "ms: " & e.msg)
    result = false
```

### Testing Connectivity

```nim
proc testConnection(): bool =
  var client = newClient("localhost", 9876.Port)

  try:
    client.connect()
    if client.ping():
      echo "✓ Connection successful"
      echo "✓ Ping successful"

      let barrels = client.listBarrels()
      echo "✓ Listed " & $barrels.len & " barrels"

      client.close()
      return true
    else:
      echo "✗ Ping failed"

  except ClientError as e:
    echo "✗ Connection failed: " & e.msg

  return false

if testConnection():
  echo "All tests passed!"
else:
  echo "Connectivity issues detected"
```

## Example: Complete Application

```nim
import network/client, tables, json, times

type
n  User = object
    id: string
    name: string
    email: string
    created: string

proc saveUser(client: var BitBarrelClient, user: User): bool =
  let userJson = %*{
    "name": user.name,
    "email": user.email,
    "created": user.created
  }

  return client.set("user:" & user.id, $userJson)

proc getUser(client: var BitBarrelClient, id: string): User =
  let data = client.get("user:" & id)
  let json = parseJson(data)

  result = User(
    id: id,
    name: json["name"].getStr(),
    email: json["email"].getStr(),
    created: json["created"].getStr()
  )

proc main() =
  var client = newClient("localhost", 9876.Port)
  client.connect()

  # Ensure database exists
  discard client.createBarrel("userdb")
  discard client.useBarrel("userdb")

  # Create and save a user
  let newUser = User(
    id: "123",
    name: "Alice Johnson",
    email: "alice@example.com",
    created: $now()
  )

  if saveUser(client, newUser):
    echo "User saved successfully"
  else:
    echo "Failed to save user"

  # Retrieve the user
  try:
    let user = getUser(client, "123")
    echo "Retrieved user: " & user.name & " <" & user.email & ">"
  except ClientError as e:
    echo "Failed to retrieve user: " & e.msg

  client.close()

when isMainModule:
  main()
```

## Next Steps

- Read the [Protocol Specification](./PROTOCOL.md) for wire format details
- Check out the [Architecture Guide](./network-architecture.md) for design details
- Explore the Go client implementation (coming soon)
- Run the examples in the `examples/network/` directory

## Support

For issues, questions, or contributions:
- GitHub Issues: [github.com/yourusername/bitbarrel/issues](https://github.com/yourusername/bitbarrel/issues)
- Documentation: [bitbarrel.io/docs](https://bitbarrel.io/docs)
- Community: [Discord/Slack/Forum]
