# BitBarrel - High-Performance Bitcask-style Key/Value Store

BitBarrel is a high-performance key/value storage engine built in Nim, using the Bitcask storage model. It offers fast writes, efficient reads, and robust crash recovery—perfect for caching, session storage, time‑series data, and large‑scale analytics.

### Why BitBarrel?
- **Three index modes** tailor performance to your use case: hash‑based (O(1)), sorted CritBit trees (range queries), and two‑tier partitioned indexes for massive datasets.
- **Cursor-based pagination** for efficient range queries and prefix searches without offset overhead.
- **Non-blocking compaction** — writes continue uninterrupted during background compaction.
- **Graph traversal** with built-in reference model for modeling relationships and detecting cycles.
- **Network enabled** with WebSocket and REST APIs, plus clients for Nim, Go, Dart/Flutter, and Python.
- **JWT authentication** with role-based access control (admin, readwrite, readonly) for secure network access.
- **LZ4 compression by default** (with Snappy as alternative), TTL, CRC32 checksums, and fast hint-file recovery.

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

### Run the examples

```bash
# Install dependencies first
nimble install

# Run basic CRUD example
nimble exampleBasic

# Run performance example
nimble examplePerformance

# Run advanced features example
nimble exampleAdvanced

# Run Pub/Sub examples
nimble examplePlugins

# Run all tests
nimble test
# See CLAUDE.md for detailed test commands including testStorage, testKeydir, testIntegration, etc.

# Run benchmark (default implementation)
nimble bench

# Run benchmark with crunchy CRC32
nimble benchCrunchy

# Run stress test
nimble stress
```

### Build with compression

```bash
# Build with LZ4 compression (default)
nimble buildLz4

# Or simply (LZ4 is the default)
nimble build

# Build with Snappy compression
nimble buildSnappy

# Build without compression
nimble buildNoCompression
```

## Client Libraries

BitBarrel provides client libraries in multiple languages for remote access via WebSocket, with JWT authentication support:

| Language | Location | Status | Auth Support |
|----------|----------|--------|--------------|
| Nim | `clients/nim/` | Full WebSocket protocol | Token in ClientConfig |
| Go | `clients/go/` | Full WebSocket protocol | Token parameter |
| Dart/Flutter | `clients/dart/` | Mobile + Web compatible | `authToken` in config |
| Python | `clients/python/` | Feature-complete WebSocket client | `auth_token` parameter, context manager |
| TypeScript | `clients/typescript/` | Full WebSocket protocol + types | Token in ClientConfig |

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

### Web Admin Console

BitBarrel includes a modern Flutter-based web admin console for visual database management. The webadmin can be served directly from the BitBarrel server or run separately during development.

**Integrated Server Mode (Recommended):**

```bash
# Build webadmin
cd webadmin && flutter build web --release && cd ..

# Start BitBarrel with integrated webadmin
./bitbarrel serve --webadmin-path=./webadmin/build/web

# Access at http://localhost:8080/admin/
```

**Separate Development Mode:**

```bash
# Start the BitBarrel server
./bitbarrel serve

# In another terminal, run the web admin
cd webadmin
flutter run -d chrome --web-port 8080
```

**Features:**
- Connection management with JWT authentication support
- Barrel management (create, delete, switch)
- Data explorer with full CRUD operations
- **Import/Export** - Bulk data operations in JSONL and CSV formats
- Query interface for prefix and range queries (CritBit mode)
- **Graph Traversal UI** - Explore _ref relationships interactively
- **Barrel Configuration Editor** - Edit sync mode, buffer sizes, compaction settings
- Statistics dashboard with comprehensive metrics
- JSON visualization with syntax highlighting
- Real-time data browsing with pagination

See [`webadmin/README.md`](webadmin/README.md) for detailed usage instructions.

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

### TypeScript/Node.js Example

```typescript
import { BitBarrelClient } from '@bitbarrel/client';

const client = new BitBarrelClient({
  host: 'localhost',
  port: 9876,
  autoConnect: true
});

// Create and use barrel
await client.createBarrel('mydb');
await client.useBarrel('mydb');

// Store data
await client.set('user:1', JSON.stringify({ name: 'Alice', age: 30 }));

// Retrieve data
const user = JSON.parse(await client.get('user:1'));
console.log(`User: ${user.name}, Age: ${user.age}`);

// Range queries (requires bmCritBit mode)
// Cursor-based pagination for efficient large dataset traversal
let cursor = '';
let allUsers = [];

while (true) {
  const result = await client.prefixQuery('user:', { limit: 100, cursor });
  allUsers.push(...result.items);

  if (!result.hasMore) break;
  cursor = result.nextCursor;
}

console.log(`Found ${allUsers.length} users`);

// Clean up
await client.close();
```

See [`clients/typescript/README.md`](clients/typescript/README.md) for full API documentation.

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
| Storage | Append‑only log, three index modes, compression (LZ4 by default, Snappy optional), binary record encoding |
| Reliability | Crash recovery, hint files with incremental recovery (40K+ keys/sec), CRC32 checksums |
| Performance | Write buffering, read‑ahead LRU, background compaction, TTL, configurable sync modes |
| Network | WebSocket binary protocol (28 commands), REST API, JWT authentication, session management, Pub/Sub messaging, presence, message history |
| Clients | Nim, Go, Dart/Flutter (mobile + web), Python, TypeScript client libraries |
| Advanced | Reference model (graph traversal), range queries, prefix search, Pub/Sub with pattern matching, cycle detection |

**Comprehensive test suite**: 33 test files with 350+ test cases, covering filesystem stress, concurrent access, crash recovery, memory pressure, network resilience, and compression.

## Pub/Sub Messaging

BitBarrel provides real-time Pub/Sub messaging with topic-based subscriptions, pattern matching, and presence tracking:

- **Topic-based subscriptions**: Subscribe to exact topics or wildcard patterns (`user/*`)
- **Message types**: Data messages, presence notifications, key-value change events
- **History**: Configurable message retention with replay on subscribe
- **Presence tracking**: See who's subscribed to topics with metadata
- **Pattern matching**: Redis-style glob patterns (`*`) for flexible subscriptions
- **Key-value integration**: Automatic publishing of key-value change events

### Examples

**Nim client** (full implementation):
```nim
import bitbarrel_client

let client = newClient("localhost", 9876.Port)
client.connect()

# Subscribe to user notifications pattern
let subId = client.subscribe("user:notifications:*")

# Publish a message
let seq = client.publish("user:notifications:123", "Welcome!")

# Handle incoming messages
client.onMessage = proc(event: PubSubEvent) =
  echo "Received: ", event.topic, " -> ", event.payload

# Clean up
client.unsubscribe(subId)
client.close()
```

**Go client** (full PubSub implementation including ListSubscribers/ListTopics):
```go
package main

import (
    "fmt"
    "github.com/tankfeed/bitbarrel-go"
)

func main() {
    client := bitbarrel.NewClient("localhost", 9876)
    client.Connect()

    // Subscribe to pattern
    subId, _ := client.Subscribe("user:notifications:*", "")

    // Publish message
    seq, _ := client.Publish("user:notifications:123", "Welcome!")

    // Handle events
    client.SetMessageHandler(func(event bitbarrel.PubSubEvent) {
        fmt.Printf("Received: %s -> %s\n", event.Topic, event.Payload)
    })
    client.StartEventReceiver()

    // Query subscribers and topics
    subs, _ := client.ListSubscribers("user:notifications:123")
    topics, _ := client.ListTopics()

    // Clean up
    client.Unsubscribe(subId)
    client.Close()
}
```

**Supported commands**: `SUBSCRIBE` (0x40), `UNSUBSCRIBE` (0x41), `PUBLISH` (0x42), `LIST_SUBSCRIBERS` (0x43), `HISTORY` (0x44), `LIST_TOPICS` (0x45), `PRESENCE` (0x46)

See [Pub/Sub Protocol Specification](docs/PROTOCOL.md#pubsub-messaging) for complete details and [Pub/Sub Client Implementation Plan](docs/PUBSUB_CLIENT_PLAN.md) for client library status.

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
| `bmHugeCritBit` | Billions of keys, limited RAM (separate API) | O(1) per range | Lazy‑loaded partitions | Massive datasets, range‑based caching, requires `openHugeBarrel()` |

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
let (humidityKeys, _, _) = metricsDb.keysByPrefix("metrics:humidity:")
echo "Humidity sensors: ", humidityKeys.len

metricsDb.close()
```

### bmHugeCritBit Mode – Large Analytics Dataset

**Note:** HugeBarrel (`bmHugeCritBit` mode) is partially implemented and uses a separate API (`openHugeBarrel()`) from regular barrels:

```nim.compilable
import bitbarrel
import storage/hugebarrel  # Import the HugeBarrel module
from bitbarrel/types import BarrelMode

var cfg = defaultBarrelConfig()
cfg.mode = BarrelMode.bmHugeCritBit
cfg.hugeConfig.maxEntriesPerRange = 1_000_000  # Split into 1M-key ranges
cfg.hugeConfig.rangeCacheSize = 5              # Keep 5 ranges in memory

# Use openHugeBarrel() instead of openBarrel() for HugeBarrel
var analyticsDb = openHugeBarrel("/tmp/analytics", cfg)

# Store user events (potentially billions)
discard analyticsDb.set("events:user:123:click:1734800000", """{"page": "/home"}""")
discard analyticsDb.set("events:user:456:purchase:1734800100", """{"amount": 99.99}""")

# Retrieve a specific event
let clickEvent = analyticsDb.get("events:user:123:click:1734800000")
if clickEvent != "":
  echo "Found click event: ", clickEvent

# Check how many ranges the data is split across
let rangeCount = analyticsDb.getRangeCount()
echo "Data distributed across ", rangeCount, " ranges"

analyticsDb.close()
```

**Network Server:** When using the network server, HugeBarrel is transparently supported through the standard `createBarrel` command with `bmHugeCritBit` mode configured.

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
- **[clients/typescript/README.md](clients/typescript/README.md)** - TypeScript/Node.js client documentation

### Getting Started
- **[docs/USER_GUIDE/tutorial.md](docs/USER_GUIDE/tutorial.md)**: Comprehensive tutorial with examples
- **[docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)**: Quick setup guide
- **[docs/GETTING_STARTED.md#automatic-barrel-discovery](docs/GETTING_STARTED.md#automatic-barrel-discovery)**: Automatic barrel discovery on startup
- **[examples/README.md](examples/README.md)**: Example documentation

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

## Running with Docker

Get started with BitBarrel in seconds using our official Docker image from GitHub Container Registry (ghcr.io), which bundles the server with a Flutter web admin interface served at `/admin/`.

### Quick Start with Docker Compose

```bash
# Start BitBarrel with integrated webadmin
docker compose up -d

# Access the services:
# - BitBarrel Server: ws://localhost:8080 or http://localhost:8080
# - Web Admin: http://localhost:8080/admin/

# View logs
docker compose logs -f
```

### Quick Start with Docker Run

The easiest way to get started is using the pre-built image from GitHub Container Registry:

```bash
# Run BitBarrel directly from GitHub Container Registry
docker run -d \
  --name bitbarrel \
  -p 8080:8080 \
  -v bitbarrel-data:/data \
  ghcr.io/gokr/bitbarrel:latest
```

Or build locally from source:

```bash
# First, build the bitbarrel binary and webadmin
nimble build
cd webadmin && flutter build web --release && cd ..

# Build and run Docker image
docker build -t bitbarrel:latest .
docker run -d \
  --name bitbarrel \
  -p 8080:8080 \
  -v bitbarrel-data:/data \
  bitbarrel:latest
```

### Features

- **Integrated webadmin**: Server serves static webadmin files at `/admin/`
- **Single port**: Both API and webadmin on port 8080
- **Zero configuration**: Works out of the box with sensible defaults
- **Environment-driven**: Easy configuration via environment variables
- **Persistent storage**: Data volume for reliable persistence
- **Security**: Runs as non-root user with JWT authentication support
- **Alpine-based**: Small image size with minimal attack surface

### Configuration

Configure BitBarrel using environment variables:

```bash
docker run -d \
  -p 8080:8080 \
  -v bitbarrel-data:/data \
  -e BITBARREL_AUTH_ENABLED=true \
  -e BITBARREL_AUTH_SECRET="your-32-char-secret" \
  -e BITBARREL_SERVER_PORT=8080 \
  -e BITBARREL_WEB_ADMIN_ENABLED=true \
  -e BITBARREL_WEB_ADMIN_PATH=/opt/bitbarrel/webadmin \
  -e BITBARREL_LOGGING_LEVEL=info \
  ghcr.io/gokr/bitbarrel:latest
```

See [docs/DOCKER.md](docs/DOCKER.md) for complete Docker documentation including:
- Building Docker images
- Advanced configuration options
- Docker Compose examples
- Security best practices
- Troubleshooting guide
- Production deployment tips

## Future Enhancements

- **Pub/Sub Messaging**: Real-time messaging system ✅ (implemented - see PROTOCOL.md)
- **Monitoring & Observability**: Prometheus metrics, health checks ✅ (implemented)
- **Replication**: Master-replica for high availability
- **Advanced Query Features**: Filtering and aggregation
- **Backup & Snapshots**: Online backup and point-in-time recovery

See [TODO.md](TODO.md) for detailed roadmap.

## License

MIT License