# BitBarrel Examples

This directory contains runnable examples demonstrating how to use the BitBarrel key-value store.

## Quick Start

### Run the Basic Example

```bash
nim c -r examples/basic/basic.nim
```

This demonstrates CRUD operations using the high-level Barrel API and is the best starting point.

### Using Nimble

```bash
# Run basic CRUD example
nimble exampleBasic

# Run performance example
nimble examplePerformance

# Run graph traversal example
nimble exampleGraph

# Run advanced features example
nimble exampleAdvanced
```

## Available Examples

### 1. Basic Example (`examples/basic/basic.nim`)

**Features demonstrated:**
- Opening a database with `openBarrel()`
- Storing key-value pairs with `barrel.set(key, value)`
- Retrieving values with `barrel.get(key)`
- Updating existing keys
- Deleting keys with `barrel.delete(key)`
- Checking existence with `barrel.exists(key)`
- Using TTL (time-to-live) for expiring keys
- Listing all keys with `barrel.listKeys()`
- Testing persistence by closing and reopening
- Viewing configuration with `barrel.getConfig()`

**Run it:**
```bash
nim c -r examples/basic/basic.nim
# or
nimble exampleBasic
```

### 2. Performance Example (`examples/basic/performance.nim`)

Demonstrates performance characteristics and tuning options.

**Features:**
- Sync mode comparison (None, Sync, Fsync)
- Write buffer size impact testing
- Batch operations vs individual writes
- Direct vs buffered writes
- Real-world mixed workload simulation
- Performance insights and best practices

**Run it:**
```bash
nim c -r examples/basic/performance.nim
# or
nimble examplePerformance
```

### 3. Graph Traversal Example (`examples/advanced/graph_traversal.nim`)

Demonstrates graph traversal patterns using the network client API.

**Note:** Requires a running BitBarrel server on port 9876. Start with `./bitbarrel -p=9876 serve`.

**Features:**
- Social graph: friends, posts, likes, comments
- Content graph: articles, tags, related content
- Organization chart: hierarchical data, management chains
- Multi-step path traversals (friends->posts, related->tags)
- Wildcard traversal and array slicing

**Run it:**
```bash
nim c -r examples/advanced/graph_traversal.nim
# or
nimble exampleGraph
```

### 4. Advanced Features Example (`examples/advanced/advanced.nim`)

Demonstrates advanced BitBarrel features.

**Features:**
- Barrel modes: bmHash, bmCritBit (range queries, prefix search)
- Compression (LZ4, Snappy) - compile-time flags
- Configuration: BarrelConfig, sync modes, buffer sizes
- Range queries and prefix search (bmCritBit mode)

**Run it:**
```bash
nim c -r examples/advanced/advanced.nim
# or
nimble exampleAdvanced
```

### 5. Pub/Sub KV Events Example (`examples/pubsub/kv_events_pubsub.nim`)

Demonstrates Pub/Sub messaging with key-value change events integration.

**Note:** Requires a running BitBarrel server on port 9876 with Pub/Sub enabled.

**Features:**
- Basic topic subscription and publishing
- Pattern matching subscriptions
- Presence tracking
- Message history retrieval
- Key-value event integration (automatic KV change notifications)
- UnsubscribeAll functionality

**Run it:**
```bash
nim c -r --path:clients/nim/src examples/pubsub/kv_events_pubsub.nim
```

### 6. Network Client Examples

**Basic Client (`examples/networking/basic_client.nim`):**
- Connect to BitBarrel server via WebSocket
- Create and use barrels
- Perform CRUD operations remotely

**Barrel Management (`examples/networking/barrels_example.nim`):**
- Manage multiple barrels over network
- Barrel switching and lifecycle management

**Run it:**
```bash
nimble exampleNetworkBasic
nimble exampleNetworkBarrels
```

## Code Examples

### Basic CRUD Pattern (High-Level API)

```nim
import bitbarrel

# Open barrel
var barrel = openBarrel("mydata.db")

# SET
discard barrel.set("user:1", "Alice")

# GET
let value = barrel.get("user:1")
echo value  # "Alice"

# EXISTS
if barrel.exists("user:1"):
  echo "Key exists"

# UPDATE
discard barrel.set("user:1", "Alice Updated")

# DELETE
discard barrel.delete("user:1")

# COUNT
echo "Total keys: ", barrel.count()

# LIST KEYS
for key in barrel.listKeys():
  echo key

# TTL (time-to-live)
discard barrel.set("session:temp", "data", ttl=3600)  # 1 hour

# CLOSE
barrel.close()
```

### Configuration Pattern

```nim
import bitbarrel
from bitbarrel/types import BarrelConfig, UserSyncMode

# High performance (less durable)
var fastConfig = defaultBarrelConfig()
fastConfig.syncMode = UserSyncMode.None
fastConfig.writeBufferSize = 1024 * 1024  # 1MB buffer
var fastDb = openBarrel("cache.db", fastConfig)

# Maximum durability (slower)
var safeConfig = defaultBarrelConfig()
safeConfig.syncMode = UserSyncMode.Fsync
safeConfig.writeBufferSize = 32 * 1024  # 32KB buffer
var safeDb = openBarrel("critical.db", safeConfig)

# Range queries with bmCritBit mode
var rangeConfig = defaultBarrelConfig()
rangeConfig.mode = BarrelMode.bmCritBit
var rangeDb = openBarrel("timeseries.db", rangeConfig)

# Query range (returns (items, cursor, hasMore))
let (items, _, _) = rangeDb.itemsInRange("key:100", "key:200")

# Query prefix (returns (keys, cursor, hasMore))
let (keys, _, _) = rangeDb.keysByPrefix("user:")
```

## Performance Characteristics

Based on running the examples:

- **Write latency (None sync)**: ~0.005ms per record (~188K ops/sec)
- **Write latency (Sync)**: ~0.005ms per record (~186K ops/sec)
- **Write latency (Fsync)**: ~0.11ms per record (~9.1K ops/sec)
- **Read latency**: ~0.006ms per record (~172K ops/sec)
- **KeyDir overhead**: ~40 bytes per key (bmHash mode), ~60 bytes per key (bmCritBit mode)
- **Record overhead**: ~20 bytes per key-value pair

### Example: Using Sync Modes

```nim
# Fastest (risk data loss on crash)
var noneConfig = defaultBarrelConfig()
noneConfig.syncMode = UserSyncMode.None

# Balanced (default)
var syncConfig = defaultBarrelConfig()
syncConfig.syncMode = UserSyncMode.Sync

# Safest (disk-level durability)
var fsyncConfig = defaultBarrelConfig()
fsyncConfig.syncMode = UserSyncMode.Fsync
```

## Best Practices

### 1. Choose the Right Barrel Mode

```nim
# bmHash: Default, fastest for simple key-value
var hashConfig = defaultBarrelConfig()
hashConfig.mode = BarrelMode.bmHash

# bmCritBit: For range queries and ordered data
var critBitConfig = defaultBarrelConfig()
critBitConfig.mode = BarrelMode.bmCritBit
```

### 2. Use Meaningful Key Patterns

Good key patterns:
```nim
"user:{user_id}"
"session:{session_id}"
"config:{setting_name}"
"metrics:temperature:{timestamp}"
```

### 3. Handle Errors Gracefully

```nim
let value = barrel.get("nonexistent_key")
if value.len == 0:
  echo "Key not found (returns empty string)"

# Or use exists() first
if not barrel.exists("key"):
  echo "Key does not exist"
```

### 4. Clean Up Resources

```nim
var barrel = openBarrel("db.data")
defer: barrel.close()  # Always close

# Or remove file after testing
if fileExists("db.data"):
  removeFile("db.data")
```

## Troubleshooting

**"Cannot open file" error**
- Check file permissions
- Ensure directory exists: `createDir("examples/data")`

**Slow performance**
- Use `-d:release` flag
- Check sync mode (Fsync is much slower)
- Try larger write buffer size

**Memory usage growing**
- KeyDir stores all keys in memory
- Each key uses ~40-60 bytes overhead
- For 1M keys: ~40-60MB RAM needed

## Example Categories

- `examples/basic/` - Basic CRUD operations and performance testing
- `examples/advanced/` - Advanced features (modes, compression, range queries)
- `examples/networking/` - Network client usage examples
- `examples/pubsub/` - Pub/Sub messaging and KV events
- `examples/plugins/` - Hook system and query result plugins
- `examples/utils.nim` - Shared utility functions for examples

## Next Steps

- Read `docs/USER_GUIDE/tutorial.md` for tutorials
- Run benchmarks: `nimble bench`
- Run tests: `nimble test`
- Review implementation in `src/`
