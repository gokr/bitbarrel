# BitBarrel - Future Enhancements & Roadmap

This document consolidates all planned and potential future enhancements for BitBarrel.

## Current Implementation Status ✅

### Core Features (Completed)
- ✅ Append-only Bitcask storage model
- ✅ Three barrel modes: Normal (hash), CritBit (sorted), HugeCritBit (two-tier massive scale)
- ✅ Range queries and prefix searches (via bmCritBit)
- ✅ In-memory KeyDir index with O(1) lookups
- ✅ CRC32 data integrity verification
- ✅ Crash recovery with hint files (40K keys/sec)
- ✅ Non-blocking background compaction (writes continue during compaction)
- ✅ Write buffering with configurable sync modes (None/Sync/Fsync)
- ✅ Read-ahead LRU buffering
- ✅ Thread-safe concurrent operations
- ✅ Compression support (LZ4 & Snappy, LZ4 as default)
- ✅ TTL support with passive expiration
- ✅ Comprehensive test suite (34 test files in hierarchical structure)
- ✅ JSON configuration parsing

### Reference Model & Graph Traversal ✅ COMPLETED
- ✅ Path specification with `->*` syntax for traversing references
- ✅ Array slicing support (e.g., `matches[0:10]`)
- ✅ Cycle detection in reference graphs
- ✅ Server-side TRAVERSE command
- ✅ Client support (Nim + Go)
- ✅ Examples demonstrating graph traversal patterns

### Network Layer ✅ COMPLETED
- ✅ WebSocket server using MummyX
- ✅ REST API endpoints for all operations
- ✅ Binary protocol (18 command types)
- ✅ Session management with BarrelRegistry
- ✅ WebSocket client using whisky library
- ✅ Range query support over network

### HugeBarrel Mode (Experimental)
- ✅ Basic two-tier storage for massive datasets
- ✅ Range partitioning with Barrel1 (CritBit)
- ✅ Barrel2 with multiple data files
- ✅ LRU caching of RangeKeyDirs
- ⚠️ Documented as experimental in `/docs/research/HUGECRITBIT.md`
- ⚠️ Lacks coordinated compaction for production use

### Performance Achieved
- **Writes**: ~250K ops/sec (None sync), ~245K ops/sec (Sync), ~11.5K ops/sec (Fsync)
- **Reads**: ~180K ops/sec
- **Recovery**: 40,000+ keys/sec with hint files
- **Memory**: ~50 bytes per key overhead
- **Stability**: Stress-tested with 25K+ keys
- **HugeBarrel**: Scales to 100K+ entries per range partition

## Client Libraries

### Go Client ✅ COMPLETED
- ✅ Located in `/clients/go/bitbarrel/`
- ✅ Full feature parity with Nim client
- ✅ ~1,649 lines of Go code
- ✅ Examples: basic, barrels, concurrent access
- ✅ Range queries and cursor pagination support

### Planned Client Libraries
- Python client library
- JavaScript/Node.js client
- Java client

### Client Features (Target)
- Connection pooling
- Automatic failover for replicas
- Request batching
- Async I/O support
- Circuit breakers

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
- ✅ JSON configuration support (COMPLETED)
- TOML configuration file support
- Environment variable overrides
- Configuration validation
- Hot reload for certain settings

### Resource Management
- Configurable connection limits
- Memory usage limits and alerts
- Disk space monitoring
- Graceful degradation under load

## Future Ideas (Lower Priority)

### Advanced Storage Formats
- Columnar storage for analytical workloads
- Log-structured merge (LSM) tree option
- Tiered storage (hot/warm/cold)
- Front-truncation compaction using `FALLOC_FL_COLLAPSE_RANGE` (Linux-specific)

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

## Known Issues

### ORC Crash in Threading Tests
Some tests have a known issue with Nim's ORC garbage collector crashing during thread cleanup (Nim issue #25253). This is NOT a BitBarrel code issue - the tests pass successfully before the crash occurs.

**Affected tests:**
- `test_client.nim` - network client tests
- `test_compact.nim` - compaction tests (7 tests pass, crash on cleanup)

**Symptoms:**
- Crash in `nim/orc.nim:unregisterCycle()` during thread shutdown
- Only affects tests using threads with circular references
- All tests complete successfully before the crash

**Workaround:**
- Run individual test files instead of full test suite
- Tests work correctly - functionality is not affected

### Experimental Features
- HugeBarrel (bmHugeCritBit mode) is documented as experimental
- Full production-grade HugeBarrel implementation is planned, see `/docs/research/HUGECRITBIT.md`
- Basic CRUD operations work but coordinated compaction is missing

### Incomplete Features
- `setBarrelConfig` on server returns error (not implemented)
- CLI interactive client is a stub only
- Prometheus `/metrics` endpoint is prepared but not implemented

## Development Priorities

### Immediate (Next Release)
1. ✅ Network protocol server (MummyX integration) - COMPLETED
2. ✅ Basic client library - COMPLETED
3. ✅ Server/client integration tests - COMPLETED
4. ✅ Go client library - COMPLETED
5. ✅ Reference traversal - COMPLETED
6. Prometheus metrics endpoint

### Short-term (2-3 Releases)
1. Pub/Sub messaging system
2. Replication (master-replica)
3. TOML configuration file support

### Medium-term (3-6 Months)
1. Multi-key transactions
2. Secondary indexes
3. Full-text search
4. Python and JavaScript client libraries

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
- [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md) - Quick start guide
- [docs/USER_GUIDE/tutorial.md](docs/USER_GUIDE/tutorial.md) - Comprehensive tutorial
- [docs/USER_GUIDE/api-reference.md](docs/USER_GUIDE/api-reference.md) - API documentation
- [docs/USER_GUIDE/configuration.md](docs/USER_GUIDE/configuration.md) - Configuration options
- [docs/DEVELOPER_GUIDE/architecture.md](docs/DEVELOPER_GUIDE/architecture.md) - System design
- [docs/DEVELOPER_GUIDE/memory-management.md](docs/DEVELOPER_GUIDE/memory-management.md) - Memory patterns
- [docs/FEATURES/compression.md](docs/FEATURES/compression.md) - Compression details
- [docs/FEATURES/data-integrity.md](docs/FEATURES/data-integrity.md) - CRC32 implementation
- [docs/FEATURES/networking.md](docs/FEATURES/networking.md) - Network protocol
- [docs/research/HUGECRITBIT.md](docs/research/HUGECRITBIT.md) - HugeBarrel experimental design

## Project Statistics

**Current Implementation:**
- Source files: 40+ modules
- Test files: 34 test suites (hierarchical structure)
  - api/ (7 files): Core, error, range tests
  - unit/ (4 files): Storage, KeyDir, compression unit tests
  - system/ (6 files): Integration, concurrency, stress tests
  - recovery/ (3 files): Recovery, compaction, hintfile tests
  - io/ (3 files): Read/Write buffer, protocol tests
  - network/ (3 files): Client/server tests
  - hugebarrel/ (4 files): HugeBarrel feature tests
  - config/ (1 file): Configuration tests
  - docs/ (1 file): Documentation examples verification
  - Plus: testutils.nim, test_cli_integration.nim
- Demo files: 5+ examples
- Documentation: Comprehensive (reorganized into USER_GUIDE, DEVELOPER_GUIDE, FEATURES, research)
- Client libraries: Nim (✅), Go (✅), Python (planned), JavaScript (planned)

**Storage Modules:**
- Core: keydir.nim, critbitindex.nim, datafile.nim, record.nim, compact.nim
- I/O: writebuffer.nim, readbuffer.nim, crc32.nim, compression.nim
- Recovery: hintfile.nim, checkpoint.nim, recovery.nim, critbithint.nim
- Range/HugeBarrel: hugebarrel.nim, rangekeydir.nim, rangesearch.nim, rangeindex.nim, rangecache.nim, rangehint.nim, orderedrange.nim

**Performance (Current):**
- Write throughput: ~250K ops/sec (None sync)
- Read throughput: ~180K ops/sec
- Recovery time: <1s with hint files
- Memory overhead: ~50 bytes per key

**Recent Refactoring (Dec 2025):**
- Test suite reorganized into hierarchical directories (testament-based discovery)
- Removed deprecated APIs: SimpleBB, SimpleConfig, DefaultConfig, merge_policy, CompactConfig
- Switched to whisky library for WebSocket client
- Added doc_examples verification task

---

**Status**: Core implementation complete and production-ready for embedded scenarios. Network layer and Go client completed. HugeBarrel is experimental. Pub/Sub and clustering planned for future releases.
