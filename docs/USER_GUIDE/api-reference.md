# BitBarrel API Reference

This document provides a comprehensive reference for the BitBarrel API. For tutorials and getting started guides, see the [User Guide](./USER_GUIDE/tutorial.md).

## Table of Contents

1. [Core Barrel API](#core-barrel-api)
2. [Configuration API](#configuration-api)
3. [Query API](#query-api)
4. [Network Client API](#network-client-api)
5. [Pub/Sub API](#pubsub-api)
6. [Plugin API](#plugin-api)

## Core Barrel API

### Opening and Closing Barrels

```nim
import bitbarrel

# Open a barrel with default configuration
var barrel = openBarrel("data.db")

# Open with custom configuration
var config = defaultBarrelConfig()
config.mode = bmCritBit
var barrel = openBarrel("data.db", config)

# Close when done
barrel.close()
```

### Basic CRUD Operations

```nim
# SET - Store a key-value pair
discard barrel.set("key", "value")

# SET with TTL (time-to-live) in seconds
discard barrel.set("temp_key", "temp_value", ttl=3600)

# GET - Retrieve a value
let value = barrel.get("key")

# Check if key exists
if barrel.exists("key"):
  echo "Key exists"

# DELETE - Remove a key-value pair
discard barrel.delete("key")

# COUNT - Get number of keys
let count = barrel.count()

# LIST KEYS - Get all keys
let keys = barrel.listKeys()
```

### Batch Operations

```nim
# Delete multiple keys
discard barrel.deleteKeys(@["key1", "key2", "key3"])

# Get multiple keys (returns seq[string] in same order)
let values = barrel.getKeys(@["key1", "key2", "key3"])
```

## Configuration API

### Barrel Configuration

```nim
import bitbarrel
from bitbarrel/types import BarrelConfig, BarrelMode, UserSyncMode

var config = defaultBarrelConfig()

# Set barrel mode
config.mode = bmHash        # Fast O(1) lookups
config.mode = bmCritBit     # Ordered keys, range queries

# Set sync mode (durability vs performance)
config.syncMode = UserSyncMode.None    # Fastest, data at risk on crash
config.syncMode = UserSyncMode.Sync    # Balanced (default)
config.syncMode = UserSyncMode.Fsync   # Safest, slower

# Set write buffer size
config.writeBufferSize = 64 * 1024  # 64KB buffer

# Open barrel with config
var barrel = openBarrel("data.db", config)
```

### Network Server Configuration

```nim
import network/server
import network/auth as authjwt

var serverConfig = ServerConfig(
  address: "0.0.0.0",
  port: 9876.Port,
  dataDir: "./data",
  workerThreads: 10,
  auth: authjwt.AuthConfig(
    enabled: true,
    secret: "your-secret-key",
    users: {
      "admin": @[authjwt.rAdmin],
      "app": @[authjwt.rReadWrite]
    }.toTable()
  )
)
```

## Query API

### Range Queries (bmCritBit mode only)

```nim
# Get keys in range [startKey, endKey)
let keys = barrel.keysInRange("user:100", "user:200")

# Get key-value pairs in range
let (items, cursor, hasMore) = barrel.itemsInRange("user:100", "user:200", limit=100)
for (key, value) in items:
  echo key, " => ", value

# Paginate through results
if hasMore:
  let (nextPage, nextCursor, stillHasMore) = barrel.itemsInRange("user:100", "user:200", limit=100, cursor=cursor)
```

### Prefix Queries (bmCritBit mode only)

```nim
# Get keys with prefix
let (keys, cursor, hasMore) = barrel.keysByPrefix("user:", limit=100)

# Get key-value pairs with prefix
let (items, cursor, hasMore) = barrel.itemsWithPrefix("user:", limit=100)

# Iterate over all matching items
do:
  var cursor = ""
  while true:
    let (items, nextCursor, hasMore) = barrel.itemsWithPrefix("user:", limit=100, cursor=cursor)
    if items.len == 0: break
    for (key, value) in items:
      echo key, " => ", value
    if not hasMore: break
    cursor = nextCursor
```

### Keys-Only Queries

```nim
# More efficient when you don't need values
let (keys, cursor, hasMore) = barrel.keysInRange("start", "end", limit=100)
let (keys, cursor, hasMore) = barrel.keysByPrefix("prefix", limit=100)
```

## Network Client API

### Connecting

```nim
import network/client

var client = newClient("localhost", 9876.Port)
client.connect()
```

### Authentication

```nim
# Connect with JWT token
var client = newClient("localhost", 9876.Port, token="eyJhbGc...")
client.connect()
```

### Barrel Operations

```nim
# Create a barrel
discard client.createBarrel("mydb")

# Use a barrel
discard client.useBarrel("mydb")

# List barrels
let barrels = client.listBarrels()

# Drop a barrel
discard client.dropBarrel("mydb")
```

### CRUD Operations (Network)

```nim
# SET
discard client.set("key", "value")

# SET with TTL (in seconds)
discard client.set("key", "value", ttl=3600)

# GET
let value = client.get("key")

# DELETE
discard client.delete("key")

# EXISTS
if client.exists("key"):
  echo "Key exists"

# COUNT
let count = client.count()
```

### Network Queries

```nim
# Range query
let (items, cursor, hasMore) = client.rangeQuery("start", "end", limit=100)

# Prefix query
let (items, cursor, hasMore) = client.prefixQuery("prefix", limit=100)

# With plugins
let plugins = @["activeOnly", "addMetadata"]
let (items, cursor, hasMore) = client.rangeQuery("start", "end", 100, cursor, plugins)
```

## Pub/Sub API

### Basic Pub/Sub

```nim
import network/client

var client = newClient("localhost", 9876.Port)
client.connect()

# Subscribe to topic
let subId = client.subscribe("chat:general")

# Set message handler
client.onMessage = proc(event: PubSubEvent) =
  echo "Received: ", event.topic, " -> ", event.payload

# Publish message
let seq = client.publish("chat:general", "Hello!")

# Unsubscribe
client.unsubscribe(subId)
```

### Pattern Matching

```nim
# Subscribe to pattern
let subId = client.subscribe("user:*:notifications")

# Subscribe with options
let subId = client.subscribe("system:alerts", SubscriptionOptions(
  enablePresence: true,
  replayHistory: true
))
```

### Presence Tracking

```nim
# Get presence info
let presence = client.getPresence("chat:general")
echo "Members: ", presence.members.len
for member in presence.members:
  echo member.username
```

### History

```nim
# Get message history
let (messages, nextCursor, hasMore) = client.history("chat:general", limit=100)

// With since sequence number
let (messages, nextCursor, hasMore) = client.history("chat:general", limit=100, sinceSeq=1000)
```

## Plugin API

### Creating a Plugin

```nim
import plugins/query_result_hooks

proc myFilter(metadata: HookMetadata,
              items: var seq[(string, string)],
              nextCursor: var string,
              hasMore: var bool) =
  items.keepItIf(it[1].contains("active"))

let pluginId = registerPlugin(
  "activeOnly",
  myFilter,
  hkRangeQuery,
  "Filter to active items only"
)
```

### Using Plugins in Queries

```nim
# Direct API
let (items, cursor, hasMore) = barrel.itemsInRange(
  startKey = "user:1000",
  endKey = "user:2000",
  limit = 100,
  cursor = "",
  plugins = @["activeOnly"]
)

# Network API
let (items, cursor, hasMore) = client.rangeQuery(
  "user:1000", "user:2000", 100, "",
  plugins = @["activeOnly"]
)
```

## Error Handling

```nim
import std/[os, strformat]

try:
  var barrel = openBarrel("data.db")
  discard barrel.set("key", "value")
except IOError as e:
  echo fmt"IO Error: {e.msg}"
except ValueError as e:
  echo fmt"Value Error: {e.msg}"
finally:
  if barrel != nil:
    barrel.close()
```

## Best Practices

### 1. Use Appropriate Sync Mode

```nim
# Cache: Fast but risky
var cacheCfg = defaultBarrelConfig()
cacheCfg.syncMode = UserSyncMode.None

# General data: Balanced (recommended default)
var generalCfg = defaultBarrelConfig()

# Critical data: Safe but slower
var criticalCfg = defaultBarrelConfig()
criticalCfg.syncMode = UserSyncMode.Fsync
```

### 2. Choose Right Barrel Mode

```nim
# Simple KV: Use bmHash (fastest lookups)
cfg.mode = bmHash

# Ordered data: Use bmCritBit (range queries)
cfg.mode = bmCritBit

# Massive datasets: Use bmHugeCritBit (when available)
cfg.mode = bmHugeCritBit
```

### 3. Handle Resources Properly

```nim
# Use defer for cleanup
var barrel = openBarrel("data.db")
defer: barrel.close()

# Or use try/finally
try:
  var barrel = openBarrel("data.db")
  # ... use barrel ...
finally:
  if barrel != nil:
    barrel.close()
```

### 4. Use Batch Operations

```nim
# Instead of multiple individual operations
discard barrel.set("key1", "value1")
discard barrel.set("key2", "value2")
discard barrel.set("key3", "value3")

# Prefer batch operations where possible
discard barrel.setMulti(@[("key1", "value1"), ("key2", "value2"), ("key3", "value3")])
```

## Additional Resources

- **[User Guide](./USER_GUIDE/tutorial.md)** - Comprehensive tutorial
- **[Getting Started](./GETTING_STARTED.md)** - Quick start guide
- **[Features](../FEATURES/)** - Detailed feature documentation
- **[Examples](../../examples/)** - Working code examples
- **[Tests](../../tests/)** - Test examples

## API Version

This API reference is for BitBarrel version 1.0.0 and later.

For questions or issues, please check the [GitHub repository](https://github.com/your-repo/bitbarrel) or contact the development team.
