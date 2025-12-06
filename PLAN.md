# High-Performance Bitcask Key/Value Store in Nim

## Overview

This document outlines a plan to build a simple but extremely performant key/value store using the Bitcask storage model in Nim. Bitcask replaces the complex memory-mapped approach with a simpler append-only log structure combined with an in-memory hash index.

## Architecture Changes from Original Plan

### Replaced Components
1. **Storage Engine**: From complex memory-mapped files → **Bitcask append-only log**
2. **Record Format**: From fixed-size arrays → **Variable-length encoding (varint)**
3. **Concurrency**: From custom thread pool →  **Nim taskpools or weave**
4. **Removed Goals**: Transactions, clustering (deferred to future)
5. **Deferred**: Compression (planned for later phase)
6. **Record Format**: From varint/custom binary → **MessagePack for record metadata**

### Why Bitcask?
Bitcask provides:
- **Simplicity**: Append-only writes eliminate complex file management
- **Predictability**: All writes are sequential (fast on SSDs/HDDs)
- **Durable**: Every write is crash-safe when properly synced
- **Fast reads**: In-memory index provides O(1) lookups
- **Fast recovery**: Can rebuild index quickly with hint files

## Bitcask Architecture

### Data File Structure

```
Data File (e.g., 000001.data)
├── Header (32 bytes)
│   ├── Magic Number (4 bytes)  - "BCKS"
│   ├── Version (4 bytes)       - uint32
│   ├── Created Timestamp (8 bytes)
│   ├── File Size (8 bytes)
│   └── Reserved (8 bytes)
├── Record 1
│   ├── CRC32 Checksum (4 bytes)
│   ├── MessagePack Metadata (variable)
│   │   ├── Timestamp (8 bytes)
│   │   ├── Key Length (varint)
│   │   └── Value Length (varint)
│   ├── Key (bytes)
│   └── Value (bytes)
├── Record 2
└── Record N...
```

### Key Directory (KeyDir)

In-memory hash table mapping keys to their location:

```nim
type
  KeyDirEntry = object
    fileId: uint32      # Which data file contains the record
    valuePos: uint64    # Position of value within file
    valueSize: uint32   # Size of value
    timestamp: int64    # For conflict resolution and TTL
    recordSize: uint32  # Total record size for merge decisions

  KeyDir* = Table[string, KeyDirEntry]
```

### MessagePack Record Format

Uses MessagePack for serializing record metadata (not the values themselves):

```nim
# Record structure in MessagePack
record = {
  "ts": int64,      # Timestamp (8 bytes)
  "kl": uint32,     # Key length
  "vl": uint32      # Value length
}

# Serialized record on disk:
[4-byte CRC32] + [MessagePack map] + [key bytes] + [value bytes]
```

**Why MessagePack for metadata?**
- Compact binary format (smaller than JSON, faster to parse)
- Self-describing: can skip/validate records during scan
- Simpler than custom binary (no manual varint implementation)
- Still very fast (minimal parsing overhead)
- Easy to extend with new fields without breaking format

**Note**: Keys and values themselves are stored as raw bytes, not MessagePack-encoded.

## Concurrency Model with Taskpools

### Architecture
```
Main Thread
├── Network Listener (async)
├── Request Router
└── KeyDir (protected by fine-grained lock)

Taskpool (N worker threads = CPU cores)
├── Read Tasks (parallel, no coordination)
├── Write Tasks (serialized via queue)
└── Merge Tasks (background)
```

### Implementation
- **Reads**: Parallel execution from taskpool, O(1) KeyDir lookup
- **Writes**: Single queue ensures ordering, append-only eliminates conflicts
- **KeyDir**: Fine-grained lock only during index updates
- **Taskpool**: Nim's `taskpools` module for work-stealing thread pool

## Merge and Compaction

### When to Merge
- Deleted records exceed 30% of file
- Total space overhead exceeds 50%
- Manual trigger via admin API
- Low-traffic hours (configurable)

### Merge Process (Three Phase)
1. **Scan**: Identify deleted/overwritten records
2. **Merge**: Background thread writes live records to new file
3. **Swap**: Atomic update of KeyDir references to new file

### Hint Files
- Stores KeyDir snapshot for fast recovery
- Generated periodically (every 10MB of writes)
- File: `000123.hint` corresponds to `000123.data`
- Reduces recovery time by 90%

## Implementation Phases

### Phase 1: Core Bitcask Engine (2 weeks)
**Goals**: Basic append-only storage with in-memory index

Files to create:
- `src/storage/datafile.nim` - Data file format and append writer
- `src/storage/keydir.nim` - In-memory hash index
- `src/storage/msgpack.nim` - MessagePack encoding/decoding
- `src/storage/record.nim` - Record format and parsing
- `src/kvs/types.nim` - Common types and constants

Tasks:
- [ ] Design file format with CRC32 checksums
- [ ] Implement append-only writer with fsync options
- [ ] Create KeyDir with thread-safe operations
- [ ] Build MessagePack serializer for record metadata
- [ ] Implement basic GET/SET/DELETE operations
- [ ] Add data file rotation at size limit
- [ ] Write comprehensive unit tests

**Performance target**: 50K writes/sec (async), 100K reads/sec

### Phase 2: Concurrency & Network (1.5 weeks)
**Goals**: Add taskpool-based concurrency and network protocol

Files to create:
- `src/concurrency/taskpool.nim` - Taskpool integration
- `src/network/protocol.nim` - Binary protocol parser
- `src/network/server.nim` - Async socket server
- `src/network/client.nim` - Client library

Tasks:
- [ ] Integrate Nim taskpools for read parallelism
- [ ] Implement write queue for serialization
- [ ] Build binary protocol (length-prefixed frames)
- [ ] Create async socket server with connection pooling
- [ ] Add client library with connection pooling
- [ ] Write integration tests with concurrent clients
- [ ] Benchmark with 100+ concurrent connections

**Performance target**: 10K concurrent connections, 50K ops/sec mixed workload

### Phase 3: Merge, Recovery & Hint Files (1.5 weeks)
**Goals**: Space reclamation and fast recovery

Files to create:
- `src/storage/merge.nim` - Merge/compaction algorithm
- `src/storage/recovery.nim` - Crash recovery
- `src/storage/hintfile.nim` - Hint file format

Tasks:
- [ ] Implement three-phase merge algorithm
- [ ] Add merge trigger conditions and scheduling
- [ ] Build hint file generation and loading
- [ ] Implement crash recovery with hint files
- [ ] Add file integrity verification
- [ ] Write recovery tests (kill -9 scenarios)
- [ ] Benchmark merge performance

**Performance target**: Recovery 1M keys in <10 seconds with hints

### Phase 4: Performance & Monitoring (1 week)
**Goals**: Optimization and observability

Files to create:
- `src/utils/metrics.nim` - Metrics collection
- `src/utils/config.nim` - Configuration management
- `src/utils/logger.nim` - Structured logging
- `tests/bench/benchmark.nim` - Performance benchmark suite

Tasks:
- [ ] Add write batching (batch by time or count)
- [ ] Optimize read-ahead and OS page cache
- [ ] Implement Prometheus metrics endpoint
- [ ] Add latency histograms and throughput counters
- [ ] Create comprehensive benchmark suite
- [ ] Tune Linux settings (noatime, scheduler)
- [ ] Profile and optimize hot paths

**Performance target**: 100K reads/sec, 25K writes/sec (sync off), 5K writes/sec (fsync)

### Phase 5: Production Hardening (1 week)
**Goals**: Make production-ready

Files to create:
- `src/kvs/config.nims` - Main configuration
- `src/kvs/main.nim` - CLI and daemon
- `docs/api.md` - API documentation
- `examples/simple_client.nim` - Usage examples

Tasks:
- [ ] Add configuration file support (TOML/JSON)
- [ ] Implement graceful shutdown (finish writes)
- [ ] Add resource limits (max connections, memory)
- [ ] Comprehensive error handling with error codes
- [ ] Write integration tests with network failures
- [ ] Create documentation and examples
- [ ] Add systemd service unit

**Performance target**: Zero data loss on kill -9, <1s startup/hot reload

### Phase 6: Compression (Future - Deferred)
**Goals**: Add optional compression for large values

Planned for post-MVP, when basic system is stable:
- Add compression threshold config (default 1KB)
- Support LZ4 for speed or Zstandard for ratio
- Compression flag in record header
- No API changes needed

## Performance Targets (Updated)

### Latency (p50/p99)
| Operation | p50 | p99 |
|-----------|-----|-----|
| GET (from index) | 5μs | 20μs |
| GET (disk read) | 50μs | 500μs |
| SET (async) | 15μs | 50μs |
| SET (sync, no fsync) | 20μs | 100μs |
| SET (fsync) | 200μs | 2ms |
| DELETE | 10μs | 30μs |

### Throughput (4-core, NVMe)
- **Read**: 100,000+ ops/sec
- **Write (async)**: 50,000+ ops/sec
- **Write (sync)**: 10,000+ ops/sec
- **Concurrent clients**: 10,000+ connections

### Resource Usage
- **Memory**: ~50 bytes per key (48B overhead + key size)
  - 10M keys = ~500MB RAM
  - 100M keys = ~5GB RAM (practical limit)
- **Disk**: 1.0-1.5x data size (append-only overhead)
- **CPU**: 60-150% at max throughput (4 cores)

### Startup/Recovery
- Empty start: <100ms
- Recovery (with hints): ~1 sec per 1M keys
- Recovery (without hints): ~5 sec per 1M keys
- Merge 1GB file: 5-10 seconds

## File Structure

```
nim-kvs/
├── src/
│   ├── kvs.nim                 # Main module
│   ├── storage/
│   │   ├── datafile.nim        # Data file format
│   │   ├── keydir.nim          # In-memory index
│   │   ├── record.nim          # Record handling
│   │   ├── msgpack.nim         # MessagePack encoding
│   │   ├── merge.nim           # Merge/compaction
│   │   ├── recovery.nim        # Crash recovery
│   │   └── hintfile.nim        # Hint files
│   ├── concurrency/
│   │   └── taskpool.nim        # Taskpool integration
│   ├── network/
│   │   ├── protocol.nim        # Binary protocol
│   │   ├── server.nim          # Network server
│   │   └── client.nim          # Client library
│   └── utils/
│       ├── config.nim          # Configuration
│       ├── metrics.nim         # Metrics
│       └── logger.nim          # Logging
├── tests/
│   ├── test_storage.nim
│   ├── test_concurrency.nim
│   ├── test_network.nim
│   └── bench/
│       ├── benchmark.nim
│       └── stress_test.nim
├── examples/
│   ├── simple_client.nim
│   └── benchmark.nim
├── docs/
│   ├── protocol.md
│   └── deployment.md
├── config
│   └── kvs.toml
├── kvs.nimble
└── README.md
```

## API Design

### Protocol Commands

```
Request:
├── Command (1 byte)
│   ├── 0x01: GET
│   ├── 0x02: SET
│   ├── 0x03: DELETE
│   ├── 0x04: EXISTS
│   └── 0x05: SCAN
├── Flags (1 byte)
├── Key Length (varint)
├── Key (bytes)
└── Value Length + Value (SET only)

Response:
├── Status (1 byte)
│   ├── 0x00: OK
│   ├── 0x01: NOT_FOUND
│   └── 0x02: ERROR
├── Value Length (varint, GET only)
└── Value (bytes, GET only)
```

### Nim Client API

```nim
import kvs/client

let client = newKvsClient("127.0.0.1", 8080)

# SET
client.set("key", "value")
client.set("key", "value", sync = true)  # Wait for disk sync

# GET
let value = client.get("key")  # Option[string]

# DELETE
client.delete("key")

# EXISTS
if client.exists("key"):
  echo "Found!"
```

## Configuration

```toml
# kvs.toml

[server]
address = "0.0.0.0"
port = 8080
max_connections = 10000

[storage]
data_dir = "./data"
max_file_size = "1GB"
max_key_size = "64KB"
max_value_size = "1MB"
sync_every_write = false  # If false, syncs every 1ms batch

[performance]
worker_threads = 4  # Number of taskpool threads
write_batch_ms = 1  # Batch writes for 1ms
write_batch_count = 100  # Or 100 writes
hint_file_interval = "10MB"

[merge]
enable = true
trigger_threshold = 0.3  # 30% fragmentation
max_merge_threads = 1

[logging]
level = "info"
file = "kvs.log"
```

## Trade-offs Made

### Accepted Limitations
1. **Memory usage**: KeyDir requires RAM (~50B per key)
2. **Write amplification**: Append-only creates overhead
3. **One writer**: Single write queue limits write parallelism
4. **No transactions**: Single operations only, no multi-key atomicity
5. **No compression**: Deferred to Phase 6
6. **No clustering**: Single-node only (for now)

### Chosen Optimizations
1. **Append-only**: Fastest possible writes
2. **In-memory index**: Fastest possible reads
3. **Taskpools**: Efficient parallelism for reads
4. **Varint encoding**: Minimal wire overhead
5. **Hint files**: Fast recovery
6. **Write batching**: High throughput with durability

## Success Criteria

### Functional
- [ ] Single-key GET/SET/DELETE operations
- [ ] Persistent storage with crash recovery
- [ ] 10,000+ concurrent client connections
- [ ] Hint files for fast recovery
- [ ] Merge/compaction for space reclamation
- [ ] Configuration file support

### Performance
- [ ] <10μs read latency (cached/indexed)
- [ ] <200μs write latency (fsync)
- [ ] 50,000+ reads/sec on 4 cores
- [ ] 10,000+ writes/sec (fsync)
- [ ] Startup in <1s (empty), <10s with 1M keys

### Reliability
- [ ] Zero data loss on kill -9 with fsync=true
- [ ] Recovery from partial writes
- [ ] Data integrity with CRC32 checksums
- [ ] File corruption detection
- [ ] Graceful degradation under load

### Testing
- [ ] >85% unit test coverage
- [ ] Integration tests for all operations
- [ ] Concurrent access tests
- [ ] Crash recovery tests
- [ ] Performance regression tests
- [ ] Long-running stress tests (24+ hours)

## Risk Assessment

### Low Risk
- **Bitcask model**: Well-understood, proven in production (Riak)
- **Nim I/O**: Mature async I/O and file handling
- **Network protocol**: Simple binary protocol
- **Taskpools**: Standard Nim concurrency solution

### Medium Risk
- **Lock-free KeyDir**: Need to avoid lock contention at scale
- **Merge performance**: Background merge must not affect reads
- **Fsync overhead**: Might limit write throughput more than expected

### Mitigation Strategies
1. **Sharded KeyDir**: Partition index if lock contention occurs
2. **Incremental merge**: Merge one file at a time
3. **Write batching**: Tune batch size to hide fsync latency
4. **Comprehensive testing**: Test early, test often

## Future Enhancements (Post-MVP)

### Phase 7: Advanced Features
- [ ] Compression (LZ4/Zstd) for values >1KB
- [ ] TTL (Time-To-Live) for automatic expiration
- [ ] Range queries/iteration (SCAN command)
- [ ] Backup API (online snapshots)

### Phase 8: Clustering
- [ ] Master-replica replication
- [ ] Consistent hashing for sharding
- [ ] Gossip protocol for failure detection
- [ ] Multi-datacenter support

### Phase 9: Advanced Operations
- [ ] Multi-key transactions (limited scope)
- [ ] Secondary indexes
- [ ] Full-text search
- [ ] Backup to S3/cloud storage

## Conclusion

This plan modifies the original to use Bitcask storage model, which offers:
- **Simplicity**: Easier to implement correctly
- **Performance**: Excellent for read-heavy and write-heavy workloads
- **Reliability**: Append-only with proper sync guarantees durability
- **Maintainability**: Simple code, easy to debug

The 6-week timeline is achievable with focus on core functionality. The deferred features (compression, transactions, clustering) can be added incrementally once the foundation is solid.

**Key files for implementation**:
- `src/storage/datafile.nim` - Core Bitcask format
- `src/storage/keydir.nim` - In-memory index
- `src/concurrency/taskpool.nim` - Parallel read processing
- `src/storage/merge.nim` - Space reclamation
- `src/storage/recovery.nim` - Crash recovery
