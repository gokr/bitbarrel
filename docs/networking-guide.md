# BitBarrel Client Library Tutorial and Usage Guide

This guide provides comprehensive documentation for using the BitBarrel network client libraries, with examples in both Nim and Go.

## Table of Contents

1. [Getting Started](#getting-started)
2. [Authentication](#authentication)
3. [Connection Management](#connection-management)
4. [Barrel Operations](#barrel-operations)
5. [Key-Value Operations](#key-value-operations)
6. [Range Queries and Iterators](#range-queries-and-iterators-bmcritbit-mode)
7. [Error Handling](#error-handling)
8. [Advanced Features](#advanced-features)
9. [Pub/Sub Messaging](#pubsub-messaging)
10. [Performance Tuning](#performance-tuning)
11. [Troubleshooting](#troubleshooting)

## Getting Started

### Server Setup

```bash
# Start the BitBarrel server (default: no authentication)
bitbarrel serve

# Initialize configuration file
bitbarrel init

# Start with custom config
bitbarrel -c=myconfig.yaml serve
```

### Authentication Setup

BitBarrel supports JWT authentication with role-based access control (RBAC).

**YAML Configuration:**
```yaml
# bitbarrel.yaml
auth:
  enabled: true
  secret: "your-32-char-secret-key-minimum"
  default_token_expiry_hours: 24

users:
  - username: "admin"
    roles:
      - "admin"
  - username: "readwrite"
    roles:
      - "readwrite"
  - username: "readonly"
    roles:
      - "readonly"
```

**Environment Variables:**
```bash
BITBARREL_AUTH_ENABLED=true
BITBARREL_AUTH_SECRET="your-32-char-secret-key"
```

**Generate JWT Tokens:**
```bash
# Generate tokens for all configured users
bitbarrel token

# Output example:
# User: admin
#   Roles: admin
#   Token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

### RBAC Roles

| Role | Permissions |
|------|-------------|
| `admin` | Full access: barrel management, all data operations |
| `readwrite` | Read and write: GET, SET, DELETE, EXISTS, COUNT |
| `readonly` | Read-only: GET, EXISTS, COUNT, range queries |

### Nim Client Quick Start

```nim
import network/client as netclient
import net

# Create a client instance
var client = netclient.newClient("localhost", 9876.Port)

# Connect to the server
try:
  client.connect()
  echo "Connected successfully"
except netclient.ClientError as e:
  echo "Failed to connect: " & e.msg
  quit(1)

# Create and use a barrel
discard client.createBarrel("mydatabase")
discard client.useBarrel("mydatabase")

# Store some data
discard client.set("greeting", "Hello, BitBarrel!")

# Retrieve data
let value = client.get("greeting")
echo value

# Clean up
client.close()
```

### Authenticated Connection

```nim
import network/client as netclient
import net

# Create client with JWT token
var client = netclient.newClient(
  host = "localhost",
  port = 9876.Port,
  token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
)

# Connect with Authorization header
client.connect()

# Now perform operations (subject to role permissions)
discard client.useBarrel("mydatabase")
discard client.set("secure", "data")
echo client.get("secure")

client.close()
```

```bash
# Generate token via CLI
bitbarrel token

# Use in production (store token in env var or secure config)
export BITBARREL_TOKEN="eyJhbGciOiJIUzI1NiIs..."
```

## Authentication

Bearer token authentication provides secure access control for BitBarrel network operations.

### Authentication Flow

```
Client              Server
  │                        │
  │-- Connect (with Authorization: Bearer <token>) -->
  │                        │
  │                        │  Verify JWT signature
  │                        │  Extract username/roles
  │                        │
  │<-- Unauthorized (401) or Connected (200) -->
  │                        │
  │-- Command (GET) --------->│
  │                        │  Check role permissions
  │<-- Response ------------│
```

### Client Configuration

**Nim Client:**
```nim
import network/client as netclient
import net

var client = netclient.newClient(
  host = "production.example.com",
  port = 9876.Port,
  token = getEnv("BITBARREL_TOKEN")
)

client.connect()
```

**Note:** JWT authentication is supported in all client libraries - Nim, Go, Dart/Flutter, Python, and TypeScript.

### Authorization Rules

| Operation | admin | readwrite | readonly |
|-----------|-------|-----------|----------|
| CREATE_BARREL, OPEN_BARREL, DROP_BARREL | YES | NO | NO |
| SET, DELETE | YES | YES | NO |
| GET, EXISTS, COUNT | YES | YES | YES |
| RANGE_QUERY, PREFIX_QUERY | YES | YES | YES |

### Common Auth Errors

**Missing Authorization Header:**
```
Error: 401 Unauthorized
Cause: Server requires authentication but client did not send Authorization header
Fix: Ensure JWT token is provided in client configuration
```

**Invalid Token:**
```
Error: 401 Unauthorized: Invalid token
Cause: JWT signature verification failed or token expired
Fix: Generate new token using `bitbarrel token`
```

**Insufficient Permissions:**
```
Error: Response status UNAUTHORIZED
Cause: User role lacks permission for the requested operation
Fix: Use a user with appropriate role or update user roles in config
```

### Go Client Quick Start

```go
package main

import (
    "fmt"
    "log"
    "github.com/gokr/bitbarrel-go"
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

# With JWT token for authentication
var client = newClient(
  host = "localhost",
  port = 9876.Port,
  token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
)

# With full configuration
let config = ClientConfig(
  host: "localhost",
  port: 9876.Port,
  connectTimeout: 5000,  # milliseconds
  token: getEnv("BITBARREL_TOKEN")  # Load from environment
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
import network/client as netclient
import net

# Best practice: explicit connection management
var client = netclient.newClient("localhost", 9876.Port)

try:
  client.connect()

  # Perform operations
  discard client.useBarrel("mydb")
  discard client.set("key", "value")

except netclient.ClientError as e:
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

# Output:
# Available barrels:
#   - users
#   - products
#   - orders
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

### Barrel Configuration

You can get and set barrel configuration at runtime. Configuration changes are persisted to a YAML file alongside the data file.

**Automatic Barrel Discovery:**

Barrels are automatically discovered when the server starts:
- Regular barrels (`.data` files) and HugeBarrels (directory structures) are detected
- YAML configuration files are auto-created for discovered barrels if they don't exist
- Discovered barrels are lazy-loaded on first access (no explicit OPEN_BARREL needed)
- Use `client.listBarrels()` to see all available barrels

This means you can place barrel data files in the server's data directory and they'll be immediately available without manual configuration.

**Get Configuration:**
```nim
# Get current barrel configuration
let config = client.getBarrelConfig("mydatabase")
echo config  # Returns JSON with all config fields
```

**Set Configuration (requires admin role):**
```nim
# Update specific configuration fields (partial update)
let configJson = """{"autoCompact": true, "compactThreshold": 0.5}"""
let updatedConfig = client.setBarrelConfig("mydatabase", configJson)
echo updatedConfig  # Returns full updated configuration
```

**Configurable Fields:**
| Field | Type | Description |
|-------|------|-------------|
| mode | string | Index mode: `"hash"`, `"critbit"`, or `"hugecritbit"` |
| writeBufferSize | int | Write buffer size in bytes |
| syncMode | string | "none", "sync", or "fsync" |
| autoCompact | bool | Enable automatic compaction |
| compactThreshold | float | Compaction trigger threshold (0.0-1.0) |
| validateCrc | bool | Validate CRC32 on reads |
| defaultTtl | int | Default TTL in seconds (0 = no expiration) |
| checkExpirationOnRead | bool | Check expiration when reading |
| deleteExpiredOnRead | bool | Delete expired records on read |

**Note:** The `mode` field (hash, critbit, hugecritbit) cannot be changed at runtime.

**Barrel Mode Configuration:**

You can create barrels with different index modes via the network API:

```nim
# Create a standard hash-mode barrel (default)
import json
discard client.createBarrel("mydb", %*{"mode": "hash"})

# Create a sorted critbit barrel for range queries
discard client.createBarrel("metrics", %*{"mode": "critbit"})

# Create a HugeBarrel for massive datasets (billions of keys)
# Note: When using direct API, use openHugeBarrel() instead of openBarrel()
let hugeConfig = %*{
  "mode": "hugecritbit",
  "hugeConfig": {
    "maxEntriesPerRange": 1000000,
    "rangeCacheSize": 5
  }
}
discard client.createBarrel("analytics", hugeConfig)
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

# Binary data (Note: limited to 32MB)
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
echo username  # "alice"

# Handling missing keys
try:
  let value = client.get("nonexistent")
  echo "Found: " & value
except ClientError as e:
  if e.msg.contains("not found"):
    echo "Key does not exist"
  else:
    raise e  # Re-raise unexpected errors

# Safe retrieval with default (built-in method)
let value = client.getOrDefault("missing", "default")
echo value  # "default"

# The getOrDefault method is available in all client libraries:
# - Nim: client.getOrDefault(key, default)
# - Go: client.GetOrDefault(key, defaultValue)
# - Python: client.get_or_default(key, default="")
# - Dart: await client.getOrDefault(key, defaultValue)
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
# Delete a single key
discard client.delete("temp:data")

# Conditional delete
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

Batch operations provide efficient multi-get, multi-set, and multi-delete capabilities through the binary protocol, significantly reducing network round trips.

```nim
# Store multiple items in one request
let pairs = @[
  ("product:1", "Laptop"),
  ("product:2", "Mouse"),
  ("product:3", "Keyboard")
]

let setCount = client.setMany(pairs)
echo "Stored ", setCount, " items"

# Retrieve multiple items in one request
let keys = @["product:1", "product:2", "product:3", "product:99"]
let foundItems = client.getMany(keys)

for (key, value) in foundItems:
  echo key, " => ", value

# Delete multiple items in one request
let keysToDelete = @["product:1", "product:2"]
let deleteCount = client.deleteMany(keysToDelete)
echo "Deleted ", deleteCount, " items"
```

**Client Methods:**
- `setMany(pairs: openArray[(string, string)]): int` - Returns count of successful sets
- `getMany(keys: openArray[string]): seq[(string, string)]` - Returns found key-value pairs
- `deleteMany(keys: openArray[string]): int` - Returns count of successful deletions

**Limits:**
- Maximum 10,000 items per batch
- Maximum 64 KB per key
- Maximum 1 MB per value

**Performance:**
- Single network round trip per batch operation
- 10x-100x faster than individual operations for large batches
- Ideal for bulk imports, initial data loading, and batch cache updates

## Range Queries and Iterators (bmCritBit Mode)

Range queries require barrels created in `bmCritBit` mode, which maintains keys in sorted order.

### Basic Range Queries

```nim
# Query key-value pairs in range [startKey, endKey)
let (items, nextCursor, hasMore) = client.rangeQuery("user:100", "user:200", limit=50)

for (key, value) in items:
  echo key & " => " & value

# If hasMore is true, fetch next page using cursor
if hasMore:
  let (nextPage, _, _) = client.rangeQuery("user:100", "user:200", limit=50, cursor=nextCursor)
```

### Range Queries with Hooks

Plugins can transform query results dynamically:

```nim
// Apply hook to filter or transform results
let (items, cursor, hasMore) = client.rangeQuery(
  startKey = "user:1000",
  endKey = "user:2000",
  limit = 100,
  cursor = "",
  hooks = @["activeOnly"]  // Apply hook
)

// Multiple hooks execute in order
let hooks = @["filterPremium", "addMetadata", "limitResults"]
let (items, cursor, hasMore) = client.rangeQuery(
  "user:0000", "user:9999", 100, "", plugins
)
```

**Available hook types:**
- Range query hooks (applied to `rangeQuery` and `itemsInRange`)
- Prefix query hooks (applied to `prefixQuery` and `itemsWithPrefix`)

**See:** [Query Hooks Feature Guide](../FEATURES/hooks.md)

### Prefix Queries

```nim
# Query all keys starting with prefix
let (items, nextCursor, hasMore) = client.prefixQuery("order:2024-", limit=100)

for (key, value) in items:
  echo "Order: " & key
```

### Prefix Queries with Hooks

```nim
// Use hooks with prefix queries
let (items, cursor, hasMore) = client.prefixQuery(
  prefix = "order:2024-",
  limit = 100,
  cursor = "",
  hooks = @["filterByStatus"]  // Apply hook
)

// Transform values before returning
let (items, cursor, hasMore) = client.prefixQuery(
  prefix = "product:",
  limit = 50,
  cursor = "",
  hooks = @["addTimestamp", "enrichData"]
)
```

### Keys-Only Queries

When you only need keys without values, keys-only queries are more efficient:

```nim
# Range query for keys only (lower network overhead)
let (keys, cursor, hasMore) = client.rangeQueryKeys("user:100", "user:200", limit=50)

# Prefix query for keys only
let (keys, cursor, hasMore) = client.prefixQueryKeys("temp:", limit=100)
```

**Benefits:**
- Reduced network transfer (only keys, no values)
- Lower memory usage on client
- Faster when values aren't needed
- Ideal for key enumeration, validation, or existence checks

### Iterator-Based Queries

For memory-efficient streaming of large datasets, use iterators that automatically handle pagination:

```nim
# Create iterator for range query (fetches pages automatically)
var iter = client.newRangeIterator("user:000", "user:999", pageSize=100)
for (key, value) in iter:
  # Process each item - only one page in memory at a time
  echo key & " => " & value

# Keys-only iterator (even more memory efficient)
var keysIter = client.newKeysIterator("user:000", "user:999", pageSize=100)
for key in keysIter:
  echo "Processing: " & key

# Prefix iterator
var prefixIter = client.newPrefixIterator("log:2024-", pageSize=50)
for (key, value) in prefixIter:
  processLogEntry(key, value)

# Keys-only prefix iterator
var keysPrefixIter = client.newKeysPrefixIterator("temp:", pageSize=50)
for key in keysPrefixIter:
  cleanupKey(key)
```

**Iterator Benefits:**
- **Automatic pagination** - Fetches next page when needed
- **Memory efficient** - Only one page in memory at a time
- **Simpler code** - No manual cursor management
- **Ideal for large datasets** - Process millions of items without running out of memory

**When to Use Iterators vs Direct Queries:**

| Use Case | Recommended Approach | Reason |
|----------|---------------------|--------|
| Small dataset (< 1000 items) | Direct queries (`rangeQuery`, `prefixQuery`) | Simpler code, all data at once |
| Large dataset (1000+ items) | Iterators | Memory efficient, automatic paging |
| Memory-constrained environment | Iterators | Controlled memory usage |
| Streaming/processing pipeline | Iterators | Process items one at a time |
| Need all results immediately | Direct queries | Single request, no iteration overhead |

### Range Count

```nim
# Count keys in range without retrieving them
let userCount = client.rangeCount("user:100", "user:200")
echo "Users in range: " & $userCount

# Count all keys in barrel
let totalCount = client.rangeCount()
echo "Total keys: " & $totalCount
```

### Example: Processing Large Datasets

```nim
# Efficiently process millions of log entries without loading all into memory
proc processLogBatch(client: var BitBarrelClient, date: string) =
  var iter = client.newPrefixIterator("log:" & date & ":", pageSize=1000)

  for (key, value) in iter:
    # Parse and process each log entry
    let entry = parseLogEntry(value)
    if entry.level == "error":
      sendAlert(entry.message)

# Process all logs for a day
processLogBatch(client, "2024-01-15")
```

### Example: Key Validation and Cleanup

```nim
# Find and validate all temporary keys
let (tempKeys, _, _) = client.prefixQueryKeys("temp:", limit=10000)

for key in tempKeys:
  if isExpired(key):
    echo "Removing expired: " & key
    discard client.delete(key)
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

# Traverse relationships (future feature)
# let results = client.traversePath("alice", "friends->*")
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

# Retrieve and parse
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
    if data.len > 32 * 1024 * 1024:  # 32MB limit
      echo "File too large (max 32MB)"
      return false

    discard client.set(key, data)
    return true
  except IOError as e:
    echo "Failed to read file: " & e.msg
    return false

# Retrieve binary data
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

# Periodic health check
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

# Run multiple concurrent workers
parallel:
  for workerId in 1..10:
    spawn worker(workerId)

echo "All workers completed"
```

## Pub/Sub Messaging

BitBarrel provides real-time Pub/Sub messaging with topic-based subscriptions, pattern matching, and presence tracking. This enables building event-driven applications, real-time notifications, and live data synchronization.

### Key Features

- **Topic-based subscriptions:** Subscribe to exact topics or Redis-style glob patterns (`*`)
- **Message types:** Data messages (`mtData`), presence notifications (`mtPresence`), key-value change events (`mtKvChange`)
- **Presence tracking:** See who's subscribed to topics with metadata
- **Message history:** Configurable retention with replay on subscribe
- **Automatic integration:** Key-value operations automatically generate Pub/Sub events

### Basic Usage (Nim Client)

```nim
import network/client

var client = newClient("localhost", 9876.Port)
client.connect()

# Subscribe to user notifications
let subId = client.subscribe("user:notifications:*")

# Handle incoming messages
client.onMessage = proc(event: PubSubEvent) =
  echo "Received on ", event.topic, ": ", event.payload

# Publish a message
let seqNo = client.publish("user:notifications:123", "Welcome!")

# Unsubscribe when done
discard client.unsubscribe(subId)
```

### Pattern Matching

```nim
# Subscribe to all user notifications
let sub1 = client.subscribe("user:*")

# Subscribe to specific pattern
let sub2 = client.subscribe("chat:room:*:messages")

# Subscribe to all topics
let sub3 = client.subscribe("*")
```

### Presence Tracking

```nim
# Get presence information for a topic
let presence = client.getPresence("chat:general")

echo "Users in chat:general:"
for member in presence.members:
  echo "  - ", member.username, " (", member.clientId, ")"
  echo "    Joined: ", member.joinedAt
  echo "    Last ping: ", member.lastPing
```

### Message History

```nim
# Get recent messages from a topic
let history = client.getHistory("chat:general", limit=50)

for event in history:
  echo event.timestamp, " - ", event.topic, ": ", event.payload

# Subscribe with history replay
let options = SubscriptionOptions(
  replayHistory: true,
  enableKvEvents: false,
  enablePresence: true
)
let subId = client.subscribe("important:events", options)
```

### Key-Value Change Events

When you perform key-value operations, Pub/Sub events are automatically generated:

```nim
# Store data - automatically publishes k/v change event
discard client.useBarrel("mydb")
discard client.set("user:profile", "{\"name\":\"Alice\"}")

# The event is published to topic: kv:mydb:user:profile
# Subscribers receive mtKvChange message type
```

### Go Client Example

```go
package main

import (
    "fmt"
    "log"
    "github.com/gokr/bitbarrel-go"
)

func main() {
    client := bitbarrel.NewClient("localhost", 9876)
    if err := client.Connect(); err != nil {
        log.Fatal(err)
    }
    defer client.Close()

    // Subscribe to pattern
    subId, err := client.Subscribe("user:notifications:*", "")
    if err != nil {
        log.Fatal(err)
    }

    // Set message handler
    client.SetMessageHandler(func(event bitbarrel.PubSubEvent) {
        fmt.Printf("Received: %s -> %s\n", event.Topic, event.Payload)
    })

    // Start receiving events (runs in background)
    go client.StartEventReceiver()

    // Publish message
    seq, err := client.Publish("user:notifications:123", "Welcome!")
    if err != nil {
        log.Fatal(err)
    }
    fmt.Printf("Published as sequence %d\n", seq)

    // Keep application running
    select{}
}
```

### Client Support Status

| Client | Pub/Sub Support | Status |
|--------|-----------------|--------|
| Nim | Full | ✅ Complete implementation (subscribe/publish + all query methods) |
| Go | Full | ✅ Complete implementation (subscribe/publish + all query methods) |
| Python | Full | ✅ Complete implementation (subscribe/publish + all query methods) |
| Dart | Full | ✅ Complete implementation (subscribe/publish + all query methods) |
| TypeScript | Full | ✅ Complete implementation (subscribe/publish + all query methods) |
| **C** | Full | ✅ Complete implementation (subscribe/publish + all query methods) |
| **Zig** | Full | ✅ Complete implementation (subscribe/publish + all query methods) |

### Best Practices

1. **Topic design:** Use hierarchical topics (`domain:entity:action:id`)
2. **Pattern efficiency:** Limit wildcard patterns to avoid excessive matching
3. **Connection management:** Use same connection for Pub/Sub and key-value operations
4. **Error handling:** Handle subscription failures and network disconnects
5. **Security:** Use authentication and consider topic naming to prevent unauthorized access

### Complete Documentation

For complete Pub/Sub documentation, see the [Pub/Sub User Guide](../USER_GUIDE/pubsub.md).

### Pub/Sub Storage Configuration

The network server supports pluggable storage backends for message history persistence. Configure storage strategies based on your requirements:

**Configuration in YAML:**
```yaml
pubsub:
  default_strategy: shared_barrel
  shared_barrel:
    path: "data/pubsub_history.data"
    max_messages_per_topic: 10000

  topic_overrides:
    - pattern: "chat:*"
      strategy: memory_only
      max_messages: 100

    - pattern: "user:*:notifications"
      strategy: per_topic_barrel
      max_messages: 1000
      compression: true

    - pattern: "system:*"
      strategy: shared_barrel
      max_messages: 50000
```

**Storage strategies:**
- `memory_only` - Fast, volatile (lost on restart)
- `shared_barrel` - Persistent, all topics in one file
- `per_topic_barrel` - Persistent, separate file per topic
- `hybrid` - Pattern-based routing

**See:** [Pub/Sub Storage Deep Dive](../FEATURES/pubsub-storage.md)

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
6. **Size matters**: Keep values under 32MB; split larger data if needed

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
- See the [Pub/Sub User Guide](../USER_GUIDE/pubsub.md) for real-time messaging documentation
- Explore the Go client implementation (coming soon)
- Run the examples in the `examples/networking/` directory

## Support

For issues, questions, or contributions:
- GitHub Issues: [github.com/yourusername/bitbarrel/issues](https://github.com/yourusername/bitbarrel/issues)
- Documentation: [bitbarrel.io/docs](https://bitbarrel.io/docs)
- Community: [Discord/Slack/Forum]
