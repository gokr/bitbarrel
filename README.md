# BitBarrel - High-Performance Bitcask-style Key/Value Store

A key/value store implemented in Nim using the enhanced Bitcask storage model.

## ✅ Status & Features

**Current Status:**
- **Test Suite**: 20 test files with 250+ test cases, all passing
- **Performance**: ~250K writes/sec (none sync), ~180K reads/sec (release build)
- **Compression**: LZ4 (~2.1x ratio) and Snappy (~1.7x ratio) support
- **Stability**: Stress-tested with 25K+ keys
- **Architecture**: Bitcask append-only with optional CRC32 verification

**Core Features (Completed):**
- ✅ Append-only storage for efficient write performance
- ✅ Three index modes: Hash table (O(1)), CritBit tree (ordered), and Ranged (lazy-loaded partitions)
- ✅ Range queries and prefix searches (CritBit mode)
- ✅ Optional CRC32 checksums for data integrity
- ✅ Binary record encoding/decoding with validation
- ✅ Basic CRUD operations (GET/SET/DELETE)
- ✅ Thread-safe KeyDir operations
- ✅ Compression support for large values (LZ4 & Snappy)

**NEW! Reference Model (Graph Traversal):**
- ✅ Reference storage in JSON with `_refs` field
- ✅ Path expression traversal (friends->team->matches)
- ✅ Wildcard support (*)
- ✅ Array slicing ([0], [-1], [0:5])
- ✅ Server-side traversal (single round-trip)
- ✅ ~30-50μs for 3-level traversals
- ✅ Cycle detection and prevention
- ✅ Client library and REST API support

**Reliability Features:**
- ✅ Crash recovery with checkpoint system
- ✅ Fast recovery at 40,000+ keys/sec with hint files
- ✅ Binary checkpoint format for persistence
- ✅ Configurable recovery options

**Performance Features:**
- ✅ Automatic compaction with background threading
- ✅ Hint file generation for fast recovery
- ✅ Space reclamation and fragmentation management
- ✅ Read-ahead LRU buffering for read performance
- ✅ Write buffering with configurable sync modes (none/sync/fsync)
- ✅ Time-to-live (TTL) support for automatic expiration

**Network Features (NEW!):**
- ✅ WebSocket server/client with binary protocol
- ✅ HTTP REST API
- ✅ Session management and barrel selection
- ✅ Binary protocol with 15 commands
- ✅ Request/response correlation with sequence numbers
- ✅ Thread-safe concurrent operations

## Quick Start

### Run Demos

```bash
# Install dependencies first
nimble install

# Run basic CRUD demo
nim c -r examples/basic_demo.nim

# Run detailed demo with stats
nim c -r examples/simple_kv_demo.nim

# Run recovery tests
nimble test-recovery

# Run all tests (including recovery)
nimble test

# Run benchmark (default implementation)
nimble bench

# Run benchmark with crunchy CRC32
nimble benchCrunchy

# Run stress test
nimble stress
```

### Build with Compression

```bash
# Build with LZ4 compression (recommended)
nimble buildLz4

# Build with Snappy compression
nimble buildSnappy

# Build without compression (default)
nimble buildDefault
```

### Use as Library

The BitBarrel can be installed via nimble and used as a library in your projects:

```nim
# Install the package
# nimble install bitbarrel

# Simple high-level API
import bitbarrel

var db = openDatabase("mydb")
discard db.set("key", "value")
echo db.get("key")  # "value"
db.close()
```

#### With Configuration

```nim
import bitbarrel
from bitbarrel/config import UserSyncMode

var cfg = defaultBarrelConfig()
cfg.syncMode = UserSyncMode.Fsync
cfg.writeBufferSize = 1024 * 1024  # 1MB buffer

var db = openDatabase("mydb", cfg)
# ... use db
```

#### Low-Level API

For advanced use cases, you can use the low-level storage API:

```nim
# For fine-grained control over data files
import bitbarrel/[lowlevelapi, barrel]

var df = lowlevelapi.openDataFile("mydb.data", 1'u32)
# Work directly with data files
```

See [docs/TUTORIAL.md](docs/TUTORIAL.md) for comprehensive examples.

### Barrel Modes

BitBarrel supports three different index modes to optimize for different use cases:

#### bmNormal Mode (Default)
Hash table-based index for O(1) lookups. Best for simple key-value operations where ordering is not needed.

```nim
import bitbarrel
from bitbarrel/types import BarrelMode

var cfg = defaultBarrelConfig()
cfg.mode = BarrelMode.bmNormal  # Default mode

var db = openBarrel("mydb", cfg)
discard db.set("key", "value")
echo db.get("key")  # "value"
```

**Performance**: O(1) lookup, ~50 bytes per key overhead
**Use case**: General-purpose key-value storage, caching, session storage

#### bmCritBit Mode
CritBit tree-based index that keeps keys sorted. Supports range queries and prefix searches with all keys in memory.

```nim
import bitbarrel
from bitbarrel/types import BarrelMode

var cfg = defaultBarrelConfig()
cfg.mode = BarrelMode.bmCritBit

var db = openBarrel("mydb", cfg)

# Store some keys
discard db.set("user:1", "Alice")
discard db.set("user:2", "Bob")
discard db.set("user:3", "Charlie")

# Range query - get all keys between "user:1" and "user:3"
let users = db.keysInRange("user:1", "user:3")
# Returns: @["user:1", "user:2", "user:3"]

# Prefix search - get all keys starting with "user:"
let allUsers = db.keysWithPrefix("user:")
# Returns: @["user:1", "user:2", "user:3"]
```

**Performance**: O(k) where k is key length, supports ordered iteration
**Use case**: Leaderboards, time-series data, prefix searches, ordered traversal

#### bmRanged Mode
Lazy-loaded hash partitions for massive datasets that don't fit in memory. Only active partitions are loaded into memory.

```nim
import bitbarrel
from bitbarrel/types import BarrelMode

var cfg = defaultBarrelConfig()
cfg.mode = BarrelMode.bmRanged
cfg.numRanges = 100      # 100 hash partitions
cfg.maxLoadedRanges = 10  # Keep max 10 partitions in memory

var db = openBarrel("bigdb", cfg)

# Store billions of keys - only active partitions stay in memory
discard db.set("key:1", "value1")
discard db.set("key:999999999", "value2")

# Check range loading stats
let stats = db.rangeStats()
echo "Loaded partitions: ", stats.loaded
```

**Performance**: O(1) lookup with ~1ms partition loading overhead when needed
**Use case**: Datasets with billions of keys, limited RAM, bursty access patterns

## Performance

### Current Performance (Release Build, Linux x86_64)

**Write Performance:**
- None sync: ~250K ops/sec (minimum durability, fast writes)
  * With write buffering enabled, data is accumulated and written sequentially
  * Ideal for batch operations, logging, and non-critical data
- Sync mode: ~245K ops/sec (OS-level durability)
  * Data is safe from application crashes
  * Good balance of performance and safety
- Fsync mode: ~11.5K ops/sec (disk-level durability)
  * Data is safe from power loss
  * Each write waits for disk confirmation

**Read Performance:**
- Sequential reads: ~180K ops/sec
- Random access: ~178K ops/sec
  * Reads require disk I/O via the in-memory index
  * Performance depends on disk speed and caching
  * Typically ~25% slower than buffered writes (None sync mode)

**Mixed Workload (80% Read / 20% Write):**
- Overall throughput: ~278K ops/sec (combined operations)
  * This averages the faster writes with slower reads
  * Actual read performance in mixed workloads: ~140K ops/sec
  * Write buffering and batching improve overall throughput

**Latency:**
- None/Sync writes: ~0.004ms (buffered, asynchronous)
- Fsync writes: 0.086ms (synchronous, confirmed)
- Reads: ~0.006ms (random disk access via index)

**Buffer Size Impact:**
- 4KB buffer: ~119K ops/sec
- 64KB-256KB buffer: ~230K ops/sec (recommended range)
- 1MB buffer: ~188K ops/sec

**Key Performance Notes:**
- **Writes can be faster than reads**: With buffering enabled and None sync mode, writes are buffered and written sequentially, while reads always require disk access
- **Pure read performance**: Without write contention, reads achieve ~180K ops/sec
- **High-level API performance**: The Barrel API with write buffering provides good performance for typical workloads
- **Sync mode trade-offs**: Choose None for speed, Sync for application safety, Fsync for data integrity

### CRC32 Implementation Performance

Two optional CRC32 implementations are available, controlled at compile time:

**Original (Default)**: Lookup table-based CRC32 in pure Nim
- **Faster** for this workload: ~600 ops/sec writes, ~100K ops/sec reads
- No external dependencies
- Pure Nim implementation
- Recommended for production use

**Crunchy**: SIMD-optimized CRC32 from crunchy library
- Available via `-d:useCrunchy` compile flag
- Currently **slower** for this workload: ~559 ops/sec writes, ~49K ops/sec reads (-7% to -53% depending on operation)
- External dependency
- May benefit different workloads or larger data sizes in the future
- Kept for testing and architectural flexibility

```bash
# Use original implementation (default, recommended)
nimble bench

# Use crunchy implementation (for testing/comparison only)
nimble benchCrunchy
```

**Note**: Our benchmarks show the original lookup table implementation outperforms crunchy for the current workload. The crunchy option is maintained for potential future benefits with different access patterns or larger data sizes. See `bench/crc32_performance_summary.md` for detailed comparison.

### Performance Characteristics

| Metric | Current | Notes |
|--------|---------|-------|
| Write throughput (none sync) | 250K ops/sec | Fastest writes, buffered |
| Write throughput (sync) | 245K ops/sec | OS-level durability |
| Write throughput (fsync) | 11.5K ops/sec | Disk-level durability |
| Read throughput | 180K ops/sec | Both sequential and random |
| Mixed workload (80R/20W) | 278K ops/sec | Combined operations (overall ops/sec) |
| Write latency (none/sync) | 0.004ms | Sub-millisecond |
| Write latency (fsync) | 0.086ms | Disk sync overhead |
| Read latency | 0.006ms | O(1) hash lookup |
| Memory per key | ~50 bytes | KeyDir index overhead |
| Recovery throughput | 40K keys/sec | With hint files |

**Performance Tips:**
- Use `none` sync for fastest writes (data at risk on crash)
- Use `sync` for balanced performance/durability
- Use `fsync` for critical data (slower but safer)
- Buffer size 64KB-256KB provides good performance
- Mixed workloads benefit from read-ahead caching

## Repository Structure

```
bitbarrel/
├── src/                      # Source code
│   ├── bitbarrel.nim        # Library & CLI entry point
│   ├── bitbarrel/           # BitBarrel API modules
│   │   ├── types.nim        # Common types
│   │   ├── barrel.nim       # High-level Barrel API
│   │   ├── lowlevelapi.nim  # Low-level wrapper
│   │   ├── config.nim       # Configuration system
│   │   ├── config_parser.nim # YAML/ENV config parsing
│   │   └── refs.nim         # Reference model utilities (NEW!)
│   ├── storage/             # Storage engine
│   │   ├── datafile.nim     # Data file format
│   │   ├── keydir.nim       # In-memory index
│   │   ├── record.nim       # Record encoding
│   │   ├── recovery.nim     # Crash recovery engine
│   │   ├── checkpoint.nim   # Checkpoint system
│   │   ├── compact.nim       # Compaction system
│   │   ├── hintfile.nim     # Hint files for fast recovery
│   │   ├── writebuffer.nim  # Write buffering system
│   │   └── readbuffer.nim   # Read-ahead LRU buffering
│   ├── network/             # Network layer (NEW!)
│   │   ├── protocol.nim     # Binary protocol
│   │   ├── server.nim       # WebSocket/HTTP server
│   │   ├── client.nim       # Client library
│   │   └── session.nim      # Session management
│   └── cli/                 # Command line interface
│       └── main.nim         # CLI server entry point
├── examples/                # Runnable demos
│   ├── basic_demo.nim       # CRUD operations demo
│   ├── simple_kv_demo.nim   # Detailed demo
│   ├── performance_tuning_demo.nim # Performance characteristics
│   ├── configuration_demo.nim # Config API usage
│   ├── social_graph_demo.nim    # Reference model social graph (NEW!)
│   ├── org_chart_demo.nim       # Reference model org chart (NEW!)
│   └── content_graph_demo.nim   # Reference model content graph (NEW!)
├── bench/                   # Benchmarks and stress tests
│   ├── unified_benchmark.nim # Comprehensive benchmark suite
│   ├── simple_bench.nim     # Performance benchmark
│   └── stress_test.nim      # Stress testing suite
├── tests/                   # Test suites
│   ├── test_barrel.nim      # Barrel API tests (30 tests)
│   ├── test_compact.nim     # Compaction tests (13 tests)
│   ├── test_compression.nim # Compression tests (8 tests)
│   ├── test_config.nim      # Configuration tests (9 tests)
│   ├── test_error_handling.nim # Error handling tests (11 tests)
│   ├── test_hintfile.nim    # Hint file tests (11 tests)
│   ├── test_hintfile_recovery.nim # Hint recovery tests (4 tests)
│   ├── test_protocol.nim    # Protocol tests (17 tests)
│   ├── test_refs.nim        # Reference model tests (22 tests, NEW!)
│   ├── test_integration.nim # Integration tests (3 tests)
│   ├── test_keydir.nim      # KeyDir tests (11 tests)
│   ├── test_recovery.nim    # Recovery tests (18 tests)
│   ├── test_session.nim     # Session tests (11 tests)
│   └── ... (more test files)
├── docs/                    # Documentation
│   ├── TUTORIAL.md          # Comprehensive tutorial
│   └── REFERENCES.md        # Reference model guide (NEW!)
├── bitbarrel.yaml          # Default configuration file
├── bitbarrel.nimble        # Nimble package definition
└── README.md               # This file
```
│   ├── test_integration.nim # Integration tests (3 tests)
│   ├── test_keydir.nim      # KeyDir tests (11 tests)
│   ├── test_compact.nim     # Compaction tests (13 tests)
│   ├── test_protocol.nim    # Protocol tests (17 tests)
│   ├── test_readbuffer.nim  # Read buffer tests (15 tests)
│   ├── test_record.nim      # Record format tests (23 tests)
│   ├── test_recovery.nim    # Recovery tests (18 tests)
│   ├── test_session.nim     # Session tests (11 tests)
│   ├── test_storage.nim     # Storage tests (3 tests)
│   ├── test_ttl.nim         # TTL tests (16 tests)
│   ├── test_writebuffer.nim # Write buffer tests (6 tests)
│   ├── test_writebuffer_simple.nim # Simple write buffer tests (6 tests)
│   └── TEST_RESULTS.md      # Detailed test report
├── docs/                    # Documentation
│   ├── TUTORIAL.md          # Comprehensive tutorial
│   ├── (future)             # API docs, deployment guide
├── bitbarrel.yaml          # Default configuration file
├── PLAN.md                 # Implementation plan
├── FEEDBACK.md             # Code review feedback
├── bitbarrel.nimble              # Nimble package definition
└── README.md               # This file
```

## Documentation

- **[docs/TUTORIAL.md](docs/TUTORIAL.md)**: Comprehensive tutorial with examples
- **[examples/README.md](examples/README.md)**: Demo documentation
- **[TEST_RESULTS.md](TEST_RESULTS.md)**: Test suite results
- **[FEEDBACK.md](FEEDBACK.md)**: Code review and improvements
- **[PLAN.md](PLAN.md)**: Implementation plan and roadmap


## Future Enhancements

- **Pub/Sub Messaging**: Real-time messaging system
- **Monitoring & Observability**: Prometheus metrics, health checks
- **Replication**: Master-replica for high availability
- **Advanced Query Features**: Filtering and aggregation
- **Backup & Snapshots**: Online backup and point-in-time recovery

See [TODO.md](TODO.md) for detailed roadmap.

## New Reference Model Feature!

The reference model adds graph traversal capabilities to BitBarrel, enabling:

- Store references between records using JSON `_refs` field
- Traverse relationships with path expressions: `friends->team->matches`
- Use wildcards and array slicing: `friends[0:5]->posts[-1]`
- Server-side processing for single round-trip queries

**Try it out:**
```bash
# Run social graph demo
nim c -r examples/social_graph_demo.nim

# Run org chart demo
nim c -r examples/org_chart_demo.nim

# Run content graph demo
nim c -r examples/content_graph_demo.nim
```

**Documentation**: See `docs/REFERENCES.md` for complete reference model guide.

## License

MIT License
