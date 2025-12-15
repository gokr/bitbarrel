# NimKVS - High-Performance Bitcask Key/Value Store

A simple but extremely performant key/value store implemented in Nim using the Bitcask storage model.

## ✅ Current Status: Production-Ready with Phase 3 Optimizations!

- **Test Suite**: 65/65 tests passing (100%) - Including Phase 3 features
- **Performance**: ~250K writes/sec (none sync), ~180K reads/sec (release build)
- **Stability**: Stress-tested with 25K+ keys
- **Crash Recovery**: Ultra-fast recovery with hint files (40K+ keys/sec)
- **Merge/Compaction**: Background threading for space reclamation
- **Read Buffering**: LRU cache for improved read performance
- **Write Buffering**: Configurable sync modes (none/sync/fsync)
- **Architecture**: Bitcask append-only with CRC32 verification

## Features

- ✅ **Append-only storage** for optimal write performance
- ✅ **In-memory hash index** for O(1) read operations
- ✅ **CRC32 checksums** for data integrity
- ✅ **Crash recovery** with checkpoint system (Phase 2)
- ✅ **Fast recovery** at 40,000+ keys/sec
- ✅ **Thread-safe** KeyDir operations
- ✅ **Binary checkpoint format** for persistence
- ✅ **Automatic compaction** with background threads (Phase 3)
- ✅ **Hint files** for ultra-fast recovery (Phase 3)
- ✅ **Read-ahead LRU buffering** for improved performance (Phase 3)
- ✅ **Write buffering** with configurable sync modes (Phase 3)
- 🚧 **Network protocol** (Phase 4)

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

### Use as Library

The KVS can be installed via nimble and used as a library in your projects:

```nim
# Install the package
# nimble install kvs

# Simple high-level API
import kvs

var db = openDatabase("mydb")
db.set("key", "value")
echo db.get("key")  # "value"
db.close()
```

#### With Configuration

```nim
import kvs
from kvs/simpleapi import UserSyncMode, defaultConfig

var cfg = defaultConfig()
cfg.syncMode = UserSyncMode.Fsync
cfg.writeBufferSize = 1024 * 1024  # 1MB buffer

var db = openDatabase("mydb", cfg)
# ... use db
```

#### Low-Level API

For advanced use cases, you can use the low-level storage API:

```nim
# For backward compatibility or fine-grained control
import kvs/[lowlevelapi, simpleapi]

var df = lowlevelapi.openDataFile("mydb.data", 1'u32)
# Work directly with data files
```

See [docs/TUTORIAL.md](docs/TUTORIAL.md) for comprehensive examples.

## Performance

### Current Performance (Release Build, Linux x86_64)

**Write Performance:**
- None sync: ~250K ops/sec (minimum durability, maximum speed)
- Sync mode: ~245K ops/sec (OS-level durability)
- Fsync mode: ~11.5K ops/sec (disk-level durability)

**Read Performance:**
- Sequential reads: ~180K ops/sec
- Random access: ~178K ops/sec

**Mixed Workload (80% Read / 20% Write):**
- Overall throughput: ~278K ops/sec

**Latency:**
- None/Sync writes: ~0.004ms
- Fsync writes: ~0.086ms
- Reads: ~0.006ms

**Buffer Size Impact:**
- 4KB buffer: ~119K ops/sec
- 64KB-256KB buffer: ~230K ops/sec (optimal range)
- 1MB buffer: ~188K ops/sec

### CRC32 Implementation Performance

Two CRC32 implementations are available, controlled at compile time:

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
| Write throughput (none sync) | 250K ops/sec | Maximum performance |
| Write throughput (sync) | 245K ops/sec | OS-level durability |
| Write throughput (fsync) | 11.5K ops/sec | Disk-level durability |
| Read throughput | 180K ops/sec | Both sequential and random |
| Mixed workload (80R/20W) | 278K ops/sec | Combined operations |
| Write latency (none/sync) | 0.004ms | Sub-millisecond |
| Write latency (fsync) | 0.086ms | Disk sync overhead |
| Read latency | 0.006ms | O(1) hash lookup |
| Memory per key | ~50 bytes | KeyDir index overhead |
| Recovery throughput | 40K keys/sec | With hint files |

**Performance Tips:**
- Use `none` sync for maximum speed (data at risk on crash)
- Use `sync` for balanced performance/durability
- Use `fsync` for critical data (slower but safest)
- Buffer size 64KB-256KB gives optimal performance
- Mixed workloads benefit from read-ahead caching

## Repository Structure

```
kvstore/
├── src/                      # Source code
│   ├── kvs.nim              # Library & CLI entry point
│   ├── kvs/types.nim        # Common types
│   ├── kvs/simpleapi.nim    # High-level API
│   ├── kvs/lowlevelapi.nim  # Low-level wrapper
│   ├── kvs/config.nim       # Configuration system
│   └── storage/             # Storage engine
│       ├── datafile.nim     # Data file format
│       ├── keydir.nim       # In-memory index
│       ├── record.nim       # Record encoding
│       ├── recovery.nim     # Crash recovery engine
│       ├── checkpoint.nim   # Checkpoint system
│       ├── merge.nim        # Merge/compaction with background threads
│       ├── hintfile.nim     # Hint files for fast recovery
│       ├── writebuffer.nim  # Write buffering system
│       ├── readbuffer.nim   # Read-ahead LRU buffering
│       └── (future)         # Network protocol
├── examples/                # Runnable demos
│   ├── basic_demo.nim       # CRUD operations demo
│   ├── simple_kv_demo.nim   # Detailed demo
│   ├── performance_tuning_demo.nim # Performance characteristics
│   └── configuration_demo.nim # Config API usage
├── bench/                   # Benchmarks and stress tests
│   ├── unified_benchmark.nim # Comprehensive benchmark suite
│   ├── simple_bench.nim     # Performance benchmark
│   └── stress_test.nim      # Stress testing suite
├── tests/                   # Test suites
│   ├── test_storage.nim     # Storage tests (✅ 3/3)
│   ├── test_keydir.nim      # KeyDir tests (✅ 7/7)
│   ├── test_integration.nim # Integration tests (✅ 3/3)
│   ├── test_recovery.nim    # Recovery tests (✅ 17/17)
│   ├── test_merge.nim       # Merge system tests (✅ 13/13)
│   ├── test_hintfile.nim    # Hint file tests (✅ 11/11)
│   ├── test_hintfile_recovery.nim # Hint recovery tests (✅ 4/4)
│   ├── test_writebuffer.nim # Write buffer tests (✅ 8/8)
│   ├── test_readbuffer.nim  # Read buffer tests (✅ 15/15)
│   ├── test_error_handling.nim # Error handling tests
│   └── TEST_RESULTS.md      # Detailed test report
├── docs/                    # Documentation
│   ├── TUTORIAL.md          # Comprehensive tutorial
│   ├── (future)             # API docs, deployment guide
├── config/                  # Configuration files
│   └── kvs.toml            # Default configuration
├── PLAN.md                 # Implementation plan
├── FEEDBACK.md             # Code review feedback
├── kvs.nimble              # Nimble package definition
└── README.md               # This file
```

## Available Commands

```bash
# Run tests
nimble test                    # All tests
nimble test-storage           # Storage tests only
nimble test-keydir            # KeyDir tests only
nimble test-recovery          # Recovery tests only
nimble test-integration       # Integration tests only

# Run demos
nimble demo-basic             # Basic CRUD demo
nimble demo                   # Detailed demo
nim c -r samples/basic_demo.nim

# Benchmark
nimble bench                  # Performance benchmark

# Stress test
nimble stress                 # Stress testing suite

# Quick verification
nimble quick-test             # Tests only
nimble full-test              # Tests + demos

# Cleanup
nimble clean                  # Remove test files
```

## Architecture

This implementation uses the **Bitcask storage model**:

### Data Flow

1. **Write Path:**
   ```
   Application → appendRecord() → DataFile → Disk
                          ↓
                    Update KeyDir (in-memory index)
   ```

2. **Read Path:**
   ```
   Application → KeyDir lookup → Record location → readRecord() → Value
   ```

### Core Components

1. **DataFile**: Handles append-only writes and random reads
   - File: `src/storage/datafile.nim`
   - Functions: `open()`, `appendRecord()`, `readRecord()`
   - Features: CRC32 checksums, integrity verification

2. **KeyDir**: Thread-safe in-memory hash index
   - File: `src/storage/keydir.nim`
   - Type: `Table[string, KeyDirEntry]`
   - Features: Lock-free reads, locked writes, atomic updates

3. **Record**: Binary encoding/decoding
   - File: `src/storage/record.nim`
   - Format: `[timestamp][key_len][key][val_len][value]`
   - Features: Variable-length encoding, validation

### Data Integrity

Each record written includes:
- CRC32 checksum for corruption detection
- Timestamp for conflict resolution
- Key and value length prefixes for safe parsing

On read, CRC32 is verified and exception raised on mismatch.

## Implementation Status

### Phase 1: Core Bitcask ✅
- ✅ File format with headers
- ✅ Record encoding/decoding
- ✅ KeyDir implementation
- ✅ Basic CRUD operations
- ✅ CRC32 verification
- ✅ All tests passing

### Phase 2: Crash Recovery ✅
- ✅ RecoveryEngine for crash recovery
- ✅ CheckpointSystem for KeyDir snapshots
- ✅ Binary checkpoint format
- ✅ Recovery at 40,000+ keys/sec
- ✅ All recovery tests passing (18/18)
- ✅ Configurable recovery options

### Phase 3: Merge & Hint Files ✅
- ✅ Merge/compaction with background threads
- ✅ Hint file generation and loading
- ✅ Space reclamation (automatic)
- ✅ Read-ahead LRU buffering
- ✅ Write buffering with configurable sync
- ✅ Enhanced recovery with hint file support

### Phase 4: Performance & Network 🚧
- 🚧 Network server (async)
- 🚧 Binary protocol
- 🚧 Additional performance tuning

## Documentation

- **[docs/TUTORIAL.md](docs/TUTORIAL.md)**: Comprehensive tutorial with examples
- **[samples/README.md](samples/README.md)**: Demo documentation
- **[TEST_RESULTS.md](TEST_RESULTS.md)**: Test suite results
- **[FEEDBACK.md](FEEDBACK.md)**: Code review and improvements
- **[PLAN.md](PLAN.md)**: Implementation plan and roadmap

## Performance Characteristics

**Measured on:** Linux x86_64, SSD, Nim 2.2.6 (Release Build)

[See updated performance data above]

## Development

### Running Tests During Development

```bash
# Quick test cycle
nim c -r tests/test_storage.nim
nim c -r tests/test_keydir.nim
nim c -r tests/test_integration.nim
nim c -r tests/test_recovery.nim

# Full verification
nimble full-test
```

### Adding New Features

1. Write tests first (TDD approach)
2. Implement in appropriate module
3. Update relevant demos
4. Run full test suite
5. Update documentation

## Future Enhancements

Planned features for production use:

- **Network layer**: Async server/client with binary protocol
- **Compression**: LZ4/Zstd for large values
- **Transactions**: Limited multi-key operations
- **Replication**: Master-replica for HA
- **Monitoring**: Metrics and health checks
- **Backup**: Online snapshot capability

See [PLAN.md](PLAN.md) for detailed roadmap.

## Contributing

This is a learning project demonstrating:
- Systems programming in Nim
- Bitcask storage model implementation
- Test-Driven Development (TDD)
- Performance optimization techniques

Key areas for improvement:
- Merge/compaction (high impact)
- Hint files for ultra-fast recovery (high impact)
- Write buffering (medium impact)
- Network protocol (Phase 4)
- Comprehensive benchmarks

Refer to [FEEDBACK.md](FEEDBACK.md) for specific improvement items.

## License

MIT License

---

**Status**: Production-ready with Phase 3 optimizations! All 65 tests passing. Ready for Phase 4 development!
