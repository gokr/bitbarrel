# BitBarrel Features Overview

BitBarrel packs a comprehensive set of features into a lightweight package. This document provides a high-level overview of key capabilities with links to detailed documentation.

## Barrel Modes: Three Indexing Strategies

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

*Detailed documentation: [Comparison with other databases](docs/COMPARISON.md)*

## Compression (LZ4/Snappy)

BitBarrel supports transparent data compression with LZ4 (default) or Snappy algorithms. Compression reduces storage footprint while maintaining high performance.

**Key features:**
- LZ4 compression enabled by default
- Snappy compression available as alternative
- Configurable compression level
- Automatic detection of incompressible data

*Detailed documentation: [Compression](docs/FEATURES/compression.md)*

## Networking & Protocol

BitBarrel includes a full network API with WebSocket binary protocol (v1.1) and REST endpoints.

**Network features:**
- WebSocket binary protocol with 28 commands
- REST API for simple HTTP access
- JWT authentication with role-based access control (admin, readwrite, readonly)
- Session management and connection pooling
- Client libraries for 7 programming languages

*Detailed documentation: [Networking](docs/FEATURES/networking.md), [Protocol Specification](docs/PROTOCOL.md), [Network Guide](docs/networking-guide.md)*

## Pub/Sub Messaging

Real-time Pub/Sub messaging with topic-based subscriptions, pattern matching, and presence tracking.

**Pub/Sub features:**
- Topic-based subscriptions with wildcard patterns (`user/*`)
- Message history with configurable retention
- Presence tracking (see who's subscribed to topics)
- Key-value change events integration
- Redis-style glob pattern matching (`*`)

*Detailed documentation: [Pub/Sub Guide](docs/USER_GUIDE/pubsub.md)*

## Graph Traversal with References

Built-in reference model for modeling relationships and detecting cycles.

**Reference features:**
- Special `_refs` field for storing relationship references
- Graph traversal API (`traversePath`, `traverseAllPaths`)
- Cycle detection to prevent infinite loops
- Bidirectional relationship support

*Detailed documentation: [Reference Model](docs/research/REFERENCES.md)*

## Hook System (Query Result Hooks)

Transform query results dynamically with custom plugins.

**Hook system features:**
- Register hooks for prefix, range, and get operations
- Transform returned values before delivery to client
- Chain multiple hooks for complex transformations
- Useful for data masking, enrichment, or format conversion

*Detailed documentation: [Hooks](docs/FEATURES/hooks.md)*

## Web Admin Console

Modern Flutter-based web interface for visual database management.

**Web admin features:**
- Connection management with JWT authentication support
- Barrel management (create, delete, switch)
- Data explorer with full CRUD operations
- Import/Export in JSONL and CSV formats
- Query interface for prefix and range queries
- Graph traversal UI for exploring `_ref` relationships
- Statistics dashboard with comprehensive metrics

*Detailed documentation: [Web Admin Console](../webadmin/README.md)*

## Data Integrity & Reliability

Enterprise-grade data protection features.

**Reliability features:**
- CRC32 checksums for data integrity validation
- Crash recovery with hint files (40K+ keys/sec recovery speed)
- Non-blocking background compaction
- Configurable durability (none, sync, fsync sync modes)
- Write buffering with four sync modes

*Detailed documentation: [Data Integrity](docs/FEATURES/data-integrity.md), [Hint Files](docs/FEATURES/hint-files.md)*

## Performance Features

Optimizations for high throughput and low latency.

**Performance features:**
- Write buffering (4KB-256KB configurable)
- Read-ahead LRU caching
- Background compaction without blocking writes
- Configurable sync modes for durability/performance trade-offs
- Mixed workload optimization

*Detailed documentation: [Performance Guide](docs/DEVELOPER_GUIDE/performance.md)*

---

**See also:** [Complete Documentation Index](docs/README.md) | [Getting Started](docs/GETTING_STARTED.md) | [Comparison with Other Databases](docs/COMPARISON.md)