# BitBarrel - High-Performance Bitcask-style Key/Value Store

BitBarrel is a high-performance key/value storage engine built in Nim, using the Bitcask storage model. It offers fast writes, efficient reads, and robust crash recovery—perfect for caching, session storage, time‑series data, and large‑scale analytics.

### Why BitBarrel?
- **Three index modes** tailor performance to your use case: hash‑based (O(1)), sorted CritBit trees (range queries), and two‑tier partitioned indexes for massive datasets.
- **Cursor-based pagination** for efficient range queries and prefix searches without offset overhead.
- **Non-blocking compaction** — writes continue uninterrupted during background compaction.
- **Graph traversal** with built-in reference model for modeling relationships and detecting cycles.
- **Network enabled** with WebSocket and REST APIs, plus clients for Nim, Go, Dart/Flutter, and Python.
- **JWT authentication** with role-based access control (admin, readwrite, readonly) for secure network access.
- **Also supports** compression (LZ4/Snappy), TTL, CRC32 checksums, and fast hint-file recovery.

## Quick Start

### Get started in 30 seconds

```nim.compilable
import bitbarrel

# Open a database with default settings (fast, durable enough for most apps)
var db = openBarrel("myapp.db")

# Store some data
discard db.set("user:42:name", "Alice")
discard db.set("user:42:email", "alice@example.com")

# Retrieve it
echo "User name: ", db.get("user:42:name")

# Clean up
db.close()
```

### Run the demos

```bash
# Install dependencies first
nimble install

# Run basic CRUD demo
nim c -r examples/basic_demo.nim

# Run detailed demo with stats
nim c -r examples/simple_kv_demo.nim

# Run recovery tests
nimble test-recovery

# Run all tests
nimble test

# Run benchmark (default implementation)
nimble bench

# Run benchmark with crunchy CRC32
nimble benchCrunchy

# Run stress test
nimble stress
```

### Build with compression

```bash
# Build with LZ4 compression (recommended)
nimble buildLz4

# Build with Snappy compression
nimble buildSnappy

# Build without compression (default)
nimble buildDefault
```

## Client Libraries

BitBarrel provides client libraries in multiple languages for remote access via WebSocket, with JWT authentication support:

| Language | Location | Status | Auth Support |
|----------|----------|--------|--------------|
| Nim | `clients/nim/` | Full WebSocket protocol | Token in ClientConfig |
| Go | `clients/go/` | Full WebSocket protocol | Token parameter |
| Dart/Flutter | `clients/dart/` | Mobile + Web compatible | `authToken` in config |
| Python | `clients/python/` | Feature-complete WebSocket client | `auth_token` parameter, context manager |

### Dart/Flutter Example

```dart
import 'package:bitbarrel/bitbarrel.dart';

final client = BitBarrelClient.localhost();
await client.connect();
await client.createBarrel('mydb');
await client.useBarrel('mydb');
await client.set('key', 'value');
final value = await client.get('key');
await client.close();
```

See [`clients/dart/README.md`](clients/dart/README.md) for full documentation.

### Go Example

```go
package main

import "github.com/tankfeed/bitbarrel-go"

client := bitbarrel.NewClient("localhost", 9876)
client.Connect()
client.CreateBarrel("mydb", "")
client.UseBarrel("mydb")
client.Set("key", "value")
value := client.Get("key")
client.Close()
```

See [`clients/go/README.md`](clients/go/README.md) for full documentation.

### JWT Authentication Example

For production deployments, enable JWT authentication on the server:

```bash
# Initialize config with auth disabled (default)
bitbarrel init

# Edit config to enable auth and add users
# bitbarrel.yaml:
#   auth:
#     enabled: true
#     secret: "your-32-char-secret-key"
#   users:
#     - username: "admin"
#       roles:
#         - "admin"
#     - username: "app"
#       roles:
#         - "readwrite"

# Generate JWT token for a user
bitbarrel token

# Start server
bitbarrel serve

# Client connects with JWT token
var client = newClient(host="localhost", port=9876.Port,
                        token="eyJhbGciOiJIUzI1...")
client.connect()
```

See [`docs/networking-guide.md`](docs/networking-guide.md) for full authentication documentation.

### Using as a Nim Library

BitBarrel can be installed via nimble and used as a library in your projects:

```nim.compilable
import bitbarrel

# Simple high-level API
var db = openBarrel("mydb")
discard db.set("key", "value")
echo db.get("key")
db.close()
```

For advanced use cases, you can access the low‑level storage API:

```nim.compilable
import bitbarrel
from bitbarrel/types import BarrelMode

# Open a barrel with CritBit mode for ordered keys
var cfg = defaultBarrelConfig()
cfg.mode = BarrelMode.bmCritBit

var db = openBarrel("/tmp/custom.db", cfg)
discard db.set("key1", "value1")
echo db.get("key1")
db.close()
```

See the [tutorial](docs/USER_GUIDE/tutorial.md) for comprehensive examples.

### Testing All Clients

```bash
# Test all client libraries (starts server on port 9876, runs tests, stops server)
nimble testClients
```

## Features at a Glance

BitBarrel packs a comprehensive set of features into a lightweight package:

| Category | Highlights |
|----------|------------|
| Storage | Append‑only log, three index modes, compression (LZ4/Snappy), binary record encoding |
| Reliability | Crash recovery, hint files with incremental recovery (40K+ keys/sec), CRC32 checksums |
| Performance | Write buffering, read‑ahead LRU, background compaction, TTL, configurable sync modes |
| Network | WebSocket binary protocol (20 commands), REST API, JWT authentication, session management, thread‑safe operations |
| Clients | Nim, Go, Dart/Flutter (mobile + web), Python client libraries |
| Advanced | Reference model (graph traversal), range queries, prefix search, cycle detection |

**Comprehensive test suite**: 27 test files with 350+ test cases, covering filesystem stress, concurrent access, crash recovery, memory pressure, and network resilience.

## Performance Highlights

Here are the key performance metrics from release builds on Linux x86_64 (ThinkPad Carbon X1 with SSD):

| Metric | Value | Context |
|--------|-------|---------|
| Write throughput (none sync) | ~188K ops/sec | Buffered, sequential writes |
| Write throughput (sync) | ~186K ops/sec | OS‑level durability |
| Write throughput (fsync) | ~9.1K ops/sec | Disk‑level durability |
| Read throughput | ~172K ops/sec | Random access via in‑memory index |
| Mixed workload (80% read) | ~137K ops/sec | Combined operations |
| Recovery speed | 40K+ keys/sec | With v2 hint files and incremental recovery |
| Write latency (none/sync) | ~0.005 ms | Sub‑millisecond |
| Read latency | ~0.006 ms | O(1) hash lookup |

*See the [DEVELOPER_GUIDE/performance.md](docs/DEVELOPER_GUIDE/performance.md) for detailed measurements and methodology.

**CRC32**: BitBarrel includes a pure Nim lookup table implementation for CRC32 validation.

### Performance Tips
- Use `none` sync for fastest writes (data at risk on crash)
- Use `sync` for balanced performance/durability
- Use `fsync` for critical data (slower but safer)
- Buffer size 4KB‑256KB provides good performance (4KB gave best results in benchmarks)
- Mixed workloads benefit from read‑ahead caching

## Barrel Modes Deep Dive

BitBarrel supports three index modes optimized for different use cases:

| Mode | Best For | Lookup | Memory | Special Features |
|------|----------|--------|--------|------------------|
| `bmHash` | General KV, caching, sessions | O(1) | ~40 bytes/key | Fastest lookups |
| `bmCritBit` | Time‑series, leaderboards, prefix searches | O(k) | ~60 bytes/key | Range queries, ordered iteration |
| `bmHugeCritBit` | Billions of keys, limited RAM | O(1) per range | Lazy‑loaded partitions | Massive datasets, range‑based caching |

### bmHash Mode – Session Store
```nim.compilable
import bitbarrel
from bitbarrel/types import BarrelMode

var cfg = defaultBarrelConfig()
cfg.mode = BarrelMode.bmHash

var sessionStore = openBarrel("sessions.db", cfg)

# Store and retrieve sessions quickly
discard sessionStore.set("sess_7a3b1c", """{"user_id": 123, "expires": 1734800000}""")
echo sessionStore.get("sess_7a3b1c")
```

### bmCritBit Mode – Time-Series Data
```nim.compilable
import bitbarrel
from bitbarrel/types import BarrelMode

var cfg = defaultBarrelConfig()
cfg.mode = BarrelMode.bmCritBit  # Sorted keys for range queries

var metricsDb = openBarrel("/tmp/metrics.db", cfg)

# Store timestamped metrics (keys are naturally sorted)
discard metricsDb.set("metrics:temp:1734800000", "22.5")
discard metricsDb.set("metrics:temp:1734800100", "23.1")
discard metricsDb.set("metrics:humidity:1734800000", "65.2")

# Range query: get all temperature metrics for a time period
let temps = metricsDb.keysInRange("metrics:temp:1734800000", "metrics:temp:1734800200")
echo "Found ", temps.len, " temperature readings"

# Prefix search: get all humidity metrics
let humidityKeys = metricsDb.keysWithPrefix("metrics:humidity:")
echo "Humidity sensors: ", humidityKeys.len

metricsDb.close()
```

### bmHugeCritBit Mode – Large Analytics Dataset
```nim.compilable
import bitbarrel
from bitbarrel/types import BarrelMode

var cfg = defaultBarrelConfig()
cfg.mode = BarrelMode.bmHugeCritBit
cfg.hugeConfig.maxEntriesPerRange = 1_000_000  # Split into 1M-key ranges
cfg.hugeConfig.rangeCacheSize = 5              # Keep 5 ranges in memory

var analyticsDb = openBarrel("/tmp/analytics.db", cfg)

# Store user events (potentially billions)
discard analyticsDb.set("events:user:123:click:1734800000", """{"page": "/home"}""")
discard analyticsDb.set("events:user:456:purchase:1734800100", """{"amount": 99.99}""")

# Query specific user's events (loads only their range into memory)
let userEvents = analyticsDb.keysWithPrefix("events:user:123:")
echo "User 123 has ", userEvents.len, " events"

analyticsDb.close()
```

## Configuration Examples

Choose the right durability for your use case:

```nim
import bitbarrel
from bitbarrel/config import UserSyncMode

# Fast caching (risk data loss on crash)
var cacheCfg = defaultBarrelConfig()
cacheCfg.syncMode = UserSyncMode.None
cacheCfg.writeBufferSize = 256 * 1024  # 256KB buffer

# General-purpose storage (safe from app crashes)
var generalCfg = defaultBarrelConfig()
generalCfg.syncMode = UserSyncMode.Sync

# Critical data (safe from power loss)
var criticalCfg = defaultBarrelConfig()
criticalCfg.syncMode = UserSyncMode.Fsync
criticalCfg.writeBufferSize = 32 * 1024  # Smaller buffer for frequent syncs

# Open databases with appropriate durability
var cacheDb = openBarrel("cache.db", cacheCfg)
var generalDb = openBarrel("data.db", generalCfg)
var criticalDb = openBarrel("critical.db", criticalCfg)
```

### Network Configuration with JWT Authentication

```nim
import network/server
import network/auth as authjwt

# Configure server with JWT authentication
var serverConfig = ServerConfig(
  address: "0.0.0.0",
  port: 9876.Port,
  dataDir: "./data",
  workerThreads: 10,
  auth: authjwt.AuthConfig(
    enabled: true,
    secret: "production-secret-key-32-chars-minimum",
    defaultTokenExpiryHours: 24,
    users: {
      "admin": @[authjwt.rAdmin],
      "readwrite": @[authjwt.rReadWrite],
      "readonly": @[authjwt.rReadonly]
    }.toTable()
  )
)

var server = newServer(serverConfig)
server.start()
```

## Documentation & Next Steps

### Client Libraries
- **[clients/dart/README.md](clients/dart/README.md)** - Dart/Flutter client (mobile + web)
- **[clients/go/README.md](clients/go/README.md)** - Go client documentation
- **[clients/nim/README.md](clients/nim/README.md)** - Nim client documentation
- **[clients/python/README.md](clients/python/README.md)** - Python client documentation

### Getting Started
- **[docs/USER_GUIDE/tutorial.md](docs/USER_GUIDE/tutorial.md)**: Comprehensive tutorial with examples
- **[docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)**: Quick setup guide
- **[examples/README.md](examples/README.md)**: Demo documentation

### Test Suite
- **[tests/README.md](tests/README.md)**: Complete test suite guide

### Performance & Benchmarks
- **[docs/DEVELOPER_GUIDE/performance.md](docs/DEVELOPER_GUIDE/performance.md)**: Benchmarking guide
- **[bench/](bench/)**: Benchmark suites

### Architecture & Design
- **[docs/DEVELOPER_GUIDE/architecture.md](docs/DEVELOPER_GUIDE/architecture.md)**: System design document
- **[docs/COMPARISON.md](docs/COMPARISON.md)**: Comparison with other databases

### Feature Documentation
- **[docs/FEATURES/hint-files.md](docs/FEATURES/hint-files.md)**: Hint file format (v2 with incremental recovery)
- **[docs/FEATURES/compression.md](docs/FEATURES/compression.md)**: LZ4 and Snappy compression
- **[docs/FEATURES/data-integrity.md](docs/FEATURES/data-integrity.md)**: CRC32 implementation
- **[docs/FEATURES/read-buffering.md](docs/FEATURES/read-buffering.md)**: Read-ahead LRU buffering
- **[docs/FEATURES/networking.md](docs/FEATURES/networking.md)**: Network protocol and client

### Advanced Topics
- **[docs/network-architecture.md](docs/network-architecture.md)**: Network layer architecture
- **[docs/research/REFERENCES.md](docs/research/REFERENCES.md)**: Reference model (graph traversal)

## Future Enhancements

- **Pub/Sub Messaging**: Real-time messaging system
- **Monitoring & Observability**: Prometheus metrics, health checks
- **Replication**: Master-replica for high availability
- **Advanced Query Features**: Filtering and aggregation
- **Backup & Snapshots**: Online backup and point-in-time recovery

See [TODO.md](TODO.md) for detailed roadmap.

## License

MIT License