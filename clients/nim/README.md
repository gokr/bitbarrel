# BitBarrel Client for Nim

A WebSocket client library for connecting to BitBarrel key-value store servers.

## Installation

```bash
nimble install bitbarrel_client
```

Or add to your `.nimble` file:

```nim
requires "bitbarrel_client >= 0.1.0"
```

## Quick Start

```nim
import bitbarrel_client

var client = newClient("localhost", 9876.Port)
client.connect()

# Create and use a barrel
discard client.createBarrel("mydb")
discard client.useBarrel("mydb")

# Store and retrieve data
discard client.set("key", "value")
echo client.get("key")  # "value"

# Check existence
echo client.exists("key")  # true

# Delete
discard client.delete("key")

# Cleanup
discard client.dropBarrel("mydb")
client.close()
```

## Features

- Binary protocol over WebSocket for efficient communication
- Barrel management (create, open, use, close, drop, list)
- Key-value operations (get, set, delete, exists, count, listKeys)
- Range queries and prefix searches (requires bmCritBit mode barrel)
- **Keys-only queries** - Efficient queries when you only need keys
- **Iterator-based queries** - Memory-efficient streaming for large datasets
- Reference traversal for graph-like data
- Statistics support: Get comprehensive barrel statistics and metrics
- **Pub/Sub messaging** - Complete WebSocket pub/sub implementation with topic/pattern subscriptions, message types, headers, event callbacks, and query methods
- Thread-safe request handling

## Concurrency Model

**Important**: This client uses a **blocking/serialized** request model.

- Requests are processed sequentially - only one request can be in-flight at a time
- A `Lock` is held for the entire send-receive cycle (`sendAndWait`) to prevent interleaving
- Multiple threads can use the client safely via the lock, but requests will be serialized
- The sequence number is validated against responses but does not enable pipelining

This design ensures correctness and simplicity for most use cases. If you need high-throughput parallel requests, use multiple client instances.

**Example of concurrent-safe (but serialized) usage:**
```nim
import std/[locks, strformat]
import ../src/bitbarrel_client

var client = newClient()
client.connect()
discard client.createBarrel("mydb")
discard client.useBarrel("mydb")

var threads: seq[Thread[void]]
var barrier: Barrier
initBarrier(barrier, 4)

proc setAndGet(n: int) =
  discard client.set(fmt"key{n}", fmt"val{n}")
  echo client.get(fmt"key{n}")

# Threads will queue due to internal locking
for i in 0..<4:
  createThread(threads[i], setAndGet, i)
for t in threads:
  joinThread(t)
```

**For parallel throughput**, use separate clients:
```nim
import std/[locks, strformat]
import ../src/bitbarrel_client

proc worker(id: int) =
  var client = newClient()
  client.connect()
  discard client.createBarrel("worker_db")
  discard client.useBarrel("worker_db")
  # ... do work ...
  client.close()

var threads: seq[Thread[int]]
for i in 0..<4:
  createThread(threads[i], worker, i)
for t in threads:
  joinThread(t)
```

## API Reference

### Client Creation

```nim
# Create with defaults (localhost:9876)
var client = newClient()

# Create with custom host/port
var client = newClient("192.168.1.100", 8080.Port)

# Create with JWT authentication
var client = newClient("localhost", 9876.Port,
                       "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...")

# Create with full config (including token)
let config = ClientConfig(
  host: "localhost",
  port: 9876.Port,
  connectTimeout: 5000,
  requestTimeout: 3000,
  token: "your-jwt-token-here"
)
var client = newClient(config)
```

### JWT Authentication

The Nim client supports JWT token authentication for secure server access:

```nim
# Server must be configured with auth enabled
# Connect with JWT token
var client = newClient("localhost", 9876.Port,
                       "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...")
client.connect()

# Token is automatically passed in the WebSocket URL
# Server validates token and grants access based on user roles
```

See the [networking guide](../../docs/networking-guide.md) for server setup instructions.

### Connection Management

```nim
client.connect()        # Connect to server
client.close()          # Close connection
client.ping()           # Check connectivity (returns bool)
client.isConnected      # Check connection status
```

### Barrel Operations

```nim
client.createBarrel("mydb")         # Create new barrel
client.createBarrel("mydb", config) # Create with JSON config
client.openBarrel("mydb")           # Open existing barrel
client.useBarrel("mydb")            # Select barrel for operations
client.closeBarrel()                # Close current barrel
client.dropBarrel("mydb")           # Delete barrel and data
client.listBarrels()                # List all barrels
```

### Key-Value Operations

```nim
client.set("key", "value")              # Store value
client.get("key")                       # Get value (raises if not found)
client.getOrDefault("key", "default")   # Get with default
client.delete("key")                    # Delete key
client.exists("key")                    # Check if key exists
client.count()                          # Count keys in barrel
client.listKeys()                       # List all keys
```

### Range Queries (bmCritBit mode)

```nim
# Range query with pagination
let (items, nextCursor, hasMore) = client.rangeQuery("a", "z", limit=100)

# Prefix query
let (items, nextCursor, hasMore) = client.prefixQuery("user:", limit=100)

# Count keys in range
let count = client.rangeCount("user:0", "user:999")
```

### Keys-Only Queries (bmCritBit mode)

When you only need keys without values, use keys-only queries for better performance:

```nim
# Range query for keys only (more efficient than full queries)
let (keys, nextCursor, hasMore) = client.rangeQueryKeys("user:0", "user:999", limit=100)

# Prefix query for keys only
let (keys, nextCursor, hasMore) = client.prefixQueryKeys("user:", limit=100)
```

**Benefits of keys-only queries:**
- Lower network overhead (only keys transferred)
- Reduced memory usage on client
- Faster when you don't need the values
- Ideal for key enumeration and validation

### Iterator-Based Queries (bmCritBit mode)

For memory-efficient streaming of large datasets, use iterators that fetch pages automatically:

```nim
# Create iterator for range query
var iter = client.newRangeIterator("user:0", "user:999", pageSize=100)
for (key, value) in iter:
  echo key, " => ", value

# Create iterator for keys-only range query
var keysIter = client.newKeysIterator("user:0", "user:999", pageSize=100)
for key in keysIter:
  echo "Key: ", key

# Create iterator for prefix query
var prefixIter = client.newPrefixIterator("user:", pageSize=100)
for (key, value) in prefixIter:
  echo key, " => ", value

# Create iterator for keys-only prefix query
var keysPrefixIter = client.newKeysPrefixIterator("user:", pageSize=100)
for key in keysPrefixIter:
  echo "Key: ", key
```

**Iterator Benefits:**
- Automatic pagination - fetches next page when needed
- Memory efficient - only one page in memory at a time
- Simpler code - no manual cursor management
- Ideal for large datasets that don't fit in memory

**When to use iterators vs direct queries:**
- Use iterators for large datasets or when memory is constrained
- Use direct queries for small datasets where you need all results at once
- Use iterators for streaming processing patterns

### Reference Traversal

```nim
let options = TraverseOptions(
  includeFullData: true,
  extractArrays: false,
  firstOnly: false
)
let results = client.traverse("user:1", "->friend", options)

# Or with defaults
let results = client.traversePath("user:1", "->friend")
```

## Pub/Sub Messaging

BitBarrel provides real-time Pub/Sub messaging with topic-based subscriptions. The Nim client has complete implementation including event handling and query methods.

### Available Methods

**Subscription Management:**
- `subscribe(topic: string): string` - Subscribe to topic or pattern with default options
- `subscribe(topic: string, options: SubscriptionOptions): string` - Subscribe with custom options
- `isSubscribed(subId: string): bool` - Check if subscription is active
- `unsubscribe(subId: string): bool` - Remove specific subscription
- `unsubscribeAll(): int` - Remove all subscriptions

**Publishing:**
- `publish(topic: string, payload: string): uint64` - Publish data message (default type mtData)
- `publish(topic: string, msgType: PubSubMessageType, payload: string): uint64` - Publish with message type
- `publish(topic: string, msgType: PubSubMessageType, payload: string, headers: string): uint64` - Publish with headers

**Event Handling:**
- `onMessage: proc(event: PubSubEvent)` - Callback for incoming Pub/Sub events
- `receiveMessages(timeoutMs: int)`: Process pending messages

**Query Methods:**
- `listSubscribers(topic: string): seq[SubscriptionInfo]` - Get topic subscribers
- `listTopics(): seq[TopicInfo]` - Get all active topics
- `getHistory(topic: string, limit: int, sinceSeq: uint64): seq[PubSubEvent]` - Get message history
- `getPresence(topic: string): PresenceInfo` - Get presence information

### Example (Basic Subscribe/Publish)

```nim
import bitbarrel_client

var client = newClient("localhost", 9876.Port)
client.connect()

# Subscribe to pattern with default options
let subId = client.subscribe("user:notifications:*")
echo "Subscribed with ID: ", subId

# Publish message (simple form - uses mtData message type)
let seq = client.publish("user:notifications:123", "Welcome to the system!")
echo "Published message with sequence: ", seq

# Check subscription status
if client.isSubscribed(subId):
  echo "Subscription is active"

# Handle incoming events
client.onMessage = proc(event: PubSubEvent) {.gcsafe.}:
  echo "Received event: ", event.topic, " -> ", event.payload

# Process pending messages
client.receiveMessages(100)

client.unsubscribe(subId)
client.close()
```

### Example (Subscribe with Options)

```nim
import bitbarrel_client

var client = newClient("localhost", 9876.Port)
client.connect()

# Subscribe with custom options (enable presence tracking)
var opts = SubscriptionOptions(
  enableKvEvents: false,
  enablePresence: true,
  replayHistory: false
)
let subId = client.subscribe("chat:room1", opts)

# Publish with headers
let headers = """{"userId": "123", "source": "web"}"""
let seq = client.publish("chat:room1", mtData, "User joined", headers)
echo "Published with sequence: ", seq
```

### Example (Query Methods)

```nim
import bitbarrel_client

var client = newClient("localhost", 9876.Port)
client.connect()

# List subscribers for a topic
let subs = client.listSubscribers("chat:general")
for s in subs:
  echo "Sub ", s.id, " by client ", s.clientId

# List all topics
let topics = client.listTopics()
for t in topics:
  echo &"Topic: {t.name}, {t.subscriberCount} subscribers, {t.messageCount} messages"

# Get message history
let history = client.getHistory("chat:general", limit=10)
for event in history:
  echo &"  [{event.sequence}] {event.payload}"

# Get presence information
let presence = client.getPresence("chat:general")
echo &"Members online: {presence.members.len}"
for member in presence.members:
  echo &"  - {member.username}"

client.close()
```

### Pub/Sub Event Types

- `mtData` (0) - Normal published messages
- `mtPresence` (1) - Member join/leave notifications
- `mtKvChange` (2) - Key-value change events (server-side)

See [Pub/Sub Protocol Specification](../../docs/PROTOCOL.md#pubsub-messaging) for complete protocol details and [tests/test_pubsub.nim](../../clients/nim/tests/test_pubsub.nim) for usage examples.

## Error Handling

All operations that can fail raise `ClientError`:

```nim
try:
  let value = client.get("missing_key")
except ClientError as e:
  echo "Error: ", e.msg
```

Use `getOrDefault` to avoid exceptions for missing keys:

```nim
let value = client.getOrDefault("missing", "default_value")
```

## Running Tests

```bash
# Run all tests
nimble test
```

Unit tests run without a server. Integration tests require a BitBarrel server on `localhost:9876` and will automatically skip if not available.

### Starting Test Server

```bash
# From bitbarrel root
./bitbarrel --port 9876
```

### Test Coverage

Tests cover all BitBarrel operations:
- Connection management
- Barrel CRUD operations
- Key-Value operations (get, set, delete, exists, count, list keys)
- Get-or-default operations
- Barrel configuration (get/set)
- Range queries and prefix searches (requires bmCritBit barrel)
- Range count operations
- Sequential and concurrent operations
- **Pub/Sub messaging** - Subscribe/publish, pattern subscriptions, message types, headers, query methods

Run pub/sub tests:
```bash
nim c -r tests/test_pubsub.nim
```

## Keeping Protocol in Sync

The protocol definition is shared with the server. To update:

```bash
nimble syncProtocol
```

This copies `protocol.nim` from the main BitBarrel source.

## Examples

See the `examples/` directory:

- `basic_usage.nim` - Basic CRUD operations
- `error_handling.nim` - Error handling patterns
- `range_queries.nim` - Range queries, keys-only queries, and iterators

Run examples:

```bash
nim c -r examples/basic_usage.nim
nim c -r examples/range_queries.nim
```


## License

MIT
