# BitBarrel - Bitcask-style Key/Value Store with Extras

BitBarrel is a high-performance key/value database built in Nim, using the Bitcask storage model at the core. Bitcask implies **append only updates** and keeping **keys with file offsets in memory** for really fast one-seek reads. BitBarrel goes beyond this model in several aspects and it can be used both compiled-in similar to Sqlite or as a traditional network server using a native threading model.

BitBarrel offers fast writes, efficient reads, and robust crash recovery. It offers a mix of key/value benefits (fast), range queries, batch operations, JSON document features like server side graph traversal, TTL support per key and last but not least - a builtin pubsub system including watchable keys. Given that it uses websockets it can also be used directly from frontends.

**Some Features:**
- Three index modes: hash‑based (O(1)), sorted CritBit trees (range queries), and two‑tier partitioned indexes for massive datasets
- Cursor-based pagination for efficient range queries and prefix searches without offset overhead
- Non-blocking compaction — writes continue uninterrupted during background compaction
- Network enabled with WebSocket and basic REST APIs, plus clients for Nim, Go, Dart/Flutter, Python, TypeScript, C, and Zig
- JWT authentication with role-based access control (admin, readwrite, readonly) for secure network access
- Web Admin UI written in Flutter using the Dart client library
- Simple to use Docker container including Web Admin UI
- 

## Quick Start

### Get started in 30 seconds

```nim
import bitbarrel

# Open a database with default settings
var db = openBarrel("myapp.db")

# Store some data
discard db.set("user:42:name", "Alice")
discard db.set("user:42:email", "alice@example.com")

# Retrieve it
echo "User name: ", db.get("user:42:name")

# Clean up
db.close()
```

**Installation:** `nimble install` • **Build:** `nimble build` • **Tests:** `nimble test`

## Advanced Examples Showcase

### Example 1: Range Queries with CritBit Mode

```nim
# Configure for ordered data and range queries
var config = defaultBarrelConfig()
config.mode = BarrelMode.bmCritBit
let db = openBarrel("timeseries.db", config)

# Store timestamped metrics (keys are naturally sorted)
for i in 0..<100:
  discard db.set(&"sensor:temp:{i}", &"{rand(20.0..30.0):.1f}")

# Range query for specific time period
let keys = db.keysInRange("sensor:temp:10", "sensor:temp:30")
echo "Found ", keys.len, " readings in range"
```

### Example 2: Pub/Sub Messaging

```nim
# Connect to server and subscribe to pattern
var client = newClient("localhost", 9876.Port)
client.connect()
let subId = client.subscribe("user:*:notifications")

# Set up real-time message handler
client.onMessage = proc(event: PubSubEvent) =
  echo "💬 ", event.topic, ": ", event.payload

# Publish messages to matching topics
discard client.publish("user:alice:notifications", "New message!")
```

### Example 3: Graph Traversal with References

```nim
# Store user with friend relationships using _refs field
let aliceData = %*{"name": "Alice", "_refs": {"friends": ["user:bob"]}}
discard client.set("user:alice", $aliceData)

# Traverse relationships
let friends = client.traversePath("user:alice", "friends")
echo "Alice has ", friends.len, " friends"
```

### Example 4: TTL & Batch Operations

```nim
# Set key with automatic expiration (local barrel)
var db = openBarrel("myapp.db")
discard db.set("session:temp", "data", ttl=5)

# Batch operations via network client
var client = newClient("localhost", 9876.Port)
client.connect()
discard client.useBarrel("myapp")
let items = [("key1", "val1"), ("key2", "val2"), ("key3", "val3")]
let successCount = client.setMany(items)
let results = client.getMany(["key1", "key2"])
```

## Client Libraries

BitBarrel provides client libraries in multiple languages for remote access via WebSocket, with JWT authentication support:

| Language | Status | Auth | Batch | TTL | Watch | Notes |
|----------|--------|------|-------|-----|-------|-------|
| Nim | ✅ Complete | ✅ | ✅ | ✅ | ✅ | Native implementation |
| Go | ✅ Complete | ✅ | ✅ | ✅ | ✅ | Native implementation |
| Python | ✅ Complete | ✅ | ✅ | ✅ | ✅ | Context manager support |
| Dart/Flutter | ✅ Complete | ✅ | ✅ | ✅ | ✅ | Mobile + Web compatible |
| TypeScript | ✅ Complete | ✅ | ✅ | ✅ | ✅ | Node.js + browser |
| C | ✅ Complete | ⚠️ | ✅ | ✅ | ✅ | Binary protocol client |
| Zig | ✅ Complete | ⚠️ | ✅ | ✅ | ✅ | Bindings to C library |

**All clients are 100% feature-complete as of 2026-01-21** • See individual client READMEs for detailed documentation.

## Performance Highlights

| Metric | Value | Context |
|--------|-------|---------|
| Write throughput (none sync) | ~188K ops/sec | Buffered, sequential writes |
| Write throughput (sync) | ~186K ops/sec | OS‑level durability |
| Write throughput (fsync) | ~9.1K ops/sec | Disk‑level durability |
| Read throughput | ~172K ops/sec | Random access via in‑memory index |
| Mixed workload (80% read) | ~137K ops/sec | Combined operations |
| Recovery speed | 40K+ keys/sec | With v2 hint files and incremental recovery |

*See [Performance Guide](docs/DEVELOPER_GUIDE/performance.md) for detailed measurements.*

## Docker Quick Start

### Run with Docker

```bash
docker run -d --name bitbarrel -p 8080:8080 -v bitbarrel-data:/data ghcr.io/gokr/bitbarrel:latest
```

*Access: Server at `ws://localhost:8080`, Web Admin at `http://localhost:8080/admin/` • [Full Docker Guide](docs/DOCKER.md)*

## Documentation

### Getting Started
- [Quick Setup](docs/GETTING_STARTED.md) - Installation and first steps
- [Tutorial](docs/USER_GUIDE/tutorial.md) - Comprehensive guide with examples
- [Examples Directory](examples/README.md) - Runnable example programs

### Advanced Features
- [Features Overview](FEATURES.md) - Barrel modes, compression, networking, and more
- [Pub/Sub Messaging](docs/USER_GUIDE/pubsub.md) - Real-time messaging guide
- [Network Guide](docs/networking-guide.md) - Client/server setup with JWT auth
- [Configuration Guide](docs/USER_GUIDE/configuration.md) - Tuning for your use case

### Developer Resources
- [Performance Guide](docs/DEVELOPER_GUIDE/performance.md) - Benchmarking and optimization
- [Testing Guide](docs/DEVELOPER_GUIDE/testing.md) - Test suite documentation
- [Architecture](docs/DEVELOPER_GUIDE/architecture.md) - System design
- [Roadmap](TODO.md) - Future enhancements and priorities

## License
MIT License