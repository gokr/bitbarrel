# BitBarrel - Future Enhancements & Roadmap

This document consolidates all planned and potential future enhancements for BitBarrel.

## Current Implementation Status ✅

### Core Features (Completed)
- ✅ Append-only Bitcask storage model
- ✅ Three barrel modes: Normal (hash), CritBit (sorted), Ranged (partitioned)
- ✅ Range queries and prefix searches (via bmCritBit)
- ✅ In-memory KeyDir index with O(1) lookups
- ✅ CRC32 data integrity verification
- ✅ Crash recovery with hint files (40K keys/sec)
- ✅ Background merge and compaction
- ✅ Write buffering with configurable sync modes (None/Sync/Fsync)
- ✅ Read-ahead LRU buffering
- ✅ Thread-safe concurrent operations
- ✅ Compression support (LZ4 & Snappy)
- ✅ TTL support with passive expiration
- ✅ Comprehensive test suite (18 test files, 237+ tests)

### Performance Achieved
- **Writes**: ~250K ops/sec (None sync), ~245K ops/sec (Sync), ~11.5K ops/sec (Fsync)
- **Reads**: ~180K ops/sec
- **Recovery**: 40,000+ keys/sec with hint files
- **Memory**: ~50 bytes per key overhead
- **Stability**: Stress-tested with 25K+ keys

## Priority 1: Network Protocol Layer

### Overview
Add network server capability using MummyX (multithreaded HTTP/WebSocket server) to enable remote access to BitBarrel instances.

### Implementation Plan

**Dependencies:**
- Add MummyX dependency to bitbarrel.nimble
- MummyX provides: Single I/O thread + TaskPools, WebSocket support, thread-safe design

**Server Components:**
- Create `src/network/server.nim` - MummyX-based WebSocket server
  - WebSocket upgrade handler for binary protocol
  - Connection lifecycle management
  - Request routing to Barrel API

**Binary Protocol Design:**
```
Message framing: [type:1][keyLen:2][key][valLen:4][value]
Command types: GET=1, SET=2, DELETE=3, EXISTS=4, PING=9
Response format: [status:1][seq:4][data]
```

**Client Library:**
- Create `src/network/client.nim` - WebSocket client library
  - Connection pool management
  - Automatic reconnection with exponential backoff
  - Request/response correlation

**Optional REST API:**
- Add HTTP endpoints for compatibility
  - GET /kv/{key} - Retrieve value
  - PUT /kv/{key} - Store value
  - DELETE /kv/{key} - Delete key
  - GET /status - Health check
  - GET /metrics - Prometheus metrics

**Testing:**
- Integration tests for network layer
- Load tests with concurrent clients (10K+ connections)
- Failure simulation (client disconnect, network issues)

**Performance Target:**
- 10,000+ concurrent client connections
- 50,000+ ops/sec mixed workload over network
- <1ms added latency for network operations

## Priority 2: Pub/Sub Messaging System

### Overview
Build a generic pub/sub messaging system on top of BitBarrel, targeting medium scale (10K topics, 10K msgs/sec) with hybrid storage for chat rooms and similar use cases.

### Design

**Architecture:**
```
Client → WebSocket → PubSubBroker → Message routing → Subscribers
                          ↓
                    MessageStore (BitBarrel backend)
                    • In-memory ring buffer (recent)
                    • Persistent storage (BitBarrel)
```

**Core Components:**
1. **PubSubBroker** (`src/pubsub/broker.nim`)
   - Topic management with hash table
   - Subscription tracking
   - Message routing with sequence numbers
   - Client connection management

2. **MessageStore** (`src/pubsub/messagestore.nim`)
   - Hybrid storage combining memory and BitBarrel
   - In-memory ring buffer per topic for recent messages
   - BitBarrel backend for persistence

3. **Protocol Handler** (`src/pubsub/protocol.nim`)
   - WebSocket command handling (SUB, UNSUB, PUB, ACK)
   - JSON message serialization
   - Error responses

**Data Model:**
```nim
Message = object
  id: string              # UUID
  topic: string           # Topic/channel name
  payload: string         # Message content
  timestamp: int64        # Unix timestamp
  sequence: uint64        # Topic-specific sequence
  headers: Table[string, string]  # Optional metadata

Subscription = object
  id: string              # Subscription ID
  topic: string           # Subscribed topic
  clientId: string        # Client identifier
  lastDelivered: uint64   # Last sequence delivered
  created: int64
```

**BitBarrel Integration:**
```nim
# Store message with topic:sequence composite key
let key = "msg:" & topic & ":" & $sequence
barrel.set(key, message.toJson())

# Update topic metadata
let metaKey = "meta:" & topic
barrel.set(metaKey, %{"lastSeq": sequence, "lastTs": timestamp})
```

**Features:**
- Topic-based pub/sub with wildcard support
- Message persistence and replay
- Last message retention per topic
- Slow subscriber detection and handling
- Message ordering guarantees per topic

**Configuration:**
```nim
PubSubConfig(
  maxTopics: 10000,                    # Maximum topics
  messagesInMemory: 1000,              # Per topic ring buffer size
  persistenceBatch: 100,               # Batch size for writes
  maxMessageSize: 64 * 1024,          # Maximum message size
  retentionHours: 24 * 7,              # Message retention period
  slowSubscriberThreshold: 5000      # Disconnect slow subscribers
)
```

## Priority 3: Advanced Operations & Features

### Replication (Master-Replica)
- Master-replica replication for high availability
- Asynchronous replication by default
- Configurable sync replication for critical data
- Replica promotion on master failure

### Multi-Key Transactions (Limited)
- Basic transaction support for multiple operations
- Batch commits/rollbacks
- Optimistic concurrency control
- Limited scope (single barrel)

### Secondary Indexes
- Additional indexes beyond primary key
- Efficient queries on indexed fields
- Automatic index maintenance on writes

### Full-Text Search
- Text search capabilities for string values
- Keyword indexing
- Search query language support

## Priority 4: Monitoring & Observability

### Prometheus Metrics
- Add `/metrics` endpoint to network server
- Track key metrics:
  - Operations per second (reads, writes, deletes)
  - Latency histograms (p50, p95, p99)
  - KeyDir size and memory usage
  - Storage metrics (file sizes, fragmentation)
  - Cache hit rates (read/write buffers)
  - Active connections (network server)
- Built-in profiling with configurable sampling

### Health Checks
- `/health` endpoint for load balancer integration
- Startup/readiness probes
- Dependency checks

### Structured Logging
- JSON log format for centralized logging
- Configurable log levels
- Request tracing with correlation IDs

## Priority 5: Operations & Management

### Backup and Snapshot
- Online snapshot capability
- Incremental backups
- Point-in-time recovery
- Backup verification tools

### Configuration Management
- TOML/JSON configuration file support
- Environment variable overrides
- Configuration validation
- Hot reload for certain settings

### Resource Management
- Configurable connection limits
- Memory usage limits and alerts
- Disk space monitoring
- Graceful degradation under load

## Priority 6: Client Libraries

### Language Bindings
- Python client library
- Go client library
- JavaScript/Node.js client
- Java client

### Client Features
- Connection pooling
- Automatic failover for replicas
- Request batching
- Async I/O support
- Circuit breakers

## Future Ideas (Lower Priority)

### Advanced Storage Formats
- Columnar storage for analytical workloads
- Log-structured merge (LSM) tree option
- Tiered storage (hot/warm/cold)

### Query Language
- Simple query DSL
- Aggregation functions
- Projection and filtering

### Security
- Authentication (TLS client certs, JWT)
- Role-based access control (RBAC)
- Encryption at rest
- Audit logging

### Cloud Integration
- Cloud storage backends (S3, GCS, Azure Blob)
- Kubernetes operator
- Helm charts
- Docker images

## Development Priorities

### Immediate (Next Release)
1. Network protocol server (MummyX integration)
2. Basic client library
3. Prometheus metrics

### Short-term (2-3 Releases)
1. Pub/Sub messaging system
2. Replication (master-replica)
3. Configuration file support

### Medium-term (3-6 Months)
1. Multi-key transactions
2. Secondary indexes
3. Full-text search
4. Additional client libraries

### Long-term (6+ Months)
1. Clustering and sharding
2. Advanced storage formats
3. Comprehensive cloud integration

## Contributing

Priority areas for contributions:
1. **Network layer** - MummyX integration, protocol design
2. **Performance** - Optimizations, benchmarks, profiling
3. **Testing** - New test cases, property-based testing
4. **Documentation** - Examples, tutorials, API docs
5. **Client libraries** - Bindings for different languages

See existing issues or create new ones for specific features.

## Getting Started

For documentation on current features:
- [docs/TUTORIAL.md](docs/TUTORIAL.md) - Comprehensive tutorial
- [docs/DESIGN.md](docs/DESIGN.md) - System design and architecture
- [docs/COMPRESSION.md](docs/COMPRESSION.md) - Compression details
- [docs/CRC.md](docs/CRC.md) - CRC32 implementation

## Project Statistics

**Current Implementation:**
- Source files: 20+ modules
- Test files: 18 test suites (237+ tests)
- Demo files: 5+ examples
- Documentation: Comprehensive

**Performance (Current):**
- Write throughput: ~250K ops/sec (None sync)
- Read throughput: ~180K ops/sec
- Recovery time: <1s with hint files
- Memory overhead: ~50 bytes per key

---

**Status**: Core implementation complete and production-ready for embedded scenarios. Network layer and cluster features planned for future releases.
