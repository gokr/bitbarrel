# BitBarrel Design Documentation

## Overview

BitBarrel is a high-performance key-value storage engine implemented in Nim using the enhanced Bitcask storage model. It uses an append-only log structure with an in-memory hash index to achieve excellent performance characteristics.

## Architecture

### Core Components

1. **Storage Engine** (src/storage/)
   - `datafile.nim` - Append-only data file format
   - `keydir.nim` - In-memory hash index mapping keys to disk positions
   - `record.nim` - Binary record format with CRC32 checksums
   - `writebuffer.nim` - Write buffering with sync modes
   - `merge.nim` - Background compaction for space reclamation
   - `recovery.nim` - Crash recovery with hint file support
   - `hintfile.nim` - Fast recovery metadata files
   - `readbuffer.nim` - Read-ahead LRU caching

2. **Barrel API** (src/bitbarrel/)
   - `barrel.nim` - High-level Barrel API with three index modes
   - `types.nim` - Common types and configuration
   - `config.nim` - Configuration management
   - `lowlevelapi.nim` - Direct storage access

### Data Flow

**Write Path:**
```
Application → Barrel API → Write Buffer → DataFile (append-only)
                                      ↓
                              Update KeyDir → In-memory index
```

**Read Path:**
```
Application → KeyDir lookup → Get disk position → DataFile read → Return value
```

## Barrel Modes

BitBarrel supports three different index modes to optimize for different use cases:

### bmNormal: Hash Table Mode (Default)
- Uses `Table[string, KeyDirEntry]` for O(1) lookups
- Simple hash map, no ordering guarantees
- Memory overhead: ~50 bytes per key
- Best for: General-purpose KV, caching, session storage

### bmCritBit: Sorted Mode
- Uses CritBitTree to maintain keys in sorted order
- Enables range queries and prefix searches
- Memory: All keys kept in sorted tree structure
- Best for: Time-series data, leaderboards, ordered traversal

### bmRanged: Lazy-Loaded Partitions
- Hash partitions across configurable ranges
- Only active partitions loaded into memory (LRU cache)
- Supports datasets 100× larger than RAM
- Best for: Analytics data with billions of keys, bursty access patterns

## File Formats

### Data File Format

BitBarrel uses binary data files with the following structure:

```
Data File (e.g., 000001.data)
├── Header (32 bytes)
│   ├── Magic Number (4 bytes) - "BBRL"
│   ├── Version (4 bytes) - uint32
│   ├── Created Timestamp (8 bytes)
│   └── Reserved (16 bytes)
└── Records (variable length)
    ├── Record 1
    │   ├── CRC32 Checksum (4 bytes)
    │   ├── Timestamp (8 bytes)
    │   ├── Key Length (4 bytes)
    │   ├── Value Length (4 bytes)
    │   ├── Key (bytes)
    │   └── Value (bytes)
    ├── Record 2
    └── ...
```

Each record includes:
- CRC32 checksum for corruption detection
- Timestamp for conflict resolution
- Variable-length key and value
- Tombstones for deletions (empty value)

### Hint File Format

For fast recovery, hint files store only metadata:

```
Hint File (e.g., 000123.hint)
├── Header (for hint format, basic metadata)
└── KeyDirEntry list for fast重建
```

This enables recovery at ~40,000 keys/sec (5-10× faster than full scan).

## Write Buffering

BitBarrel provides four sync modes to balance performance and durability:

1. **None**: Maximum speed, data cached by OS (not synced to disk)
   - ~250K ops/sec
   - Data loss on crash acceptable (caching)

2. **Sync**: OS-level durability
   - ~245K ops/sec
   - Data synced to OS buffers
   - Safe from app crashes, not power loss

3. **Fsync**: Full disk-level durability
   - ~11.5K ops/sec
   - Each write waits for disk confirmation
   - Safe from power loss

## Merge and Compaction

Background process reclaims space from deleted/overwritten records:

**Trigger Conditions:**
- Deleted records exceed 30% of file
- Total space overhead exceeds 50%
- Manual trigger via API

**Merge Process:**
1. Scan: Identify live records (non-deleted, latest timestamp)
2. Merge: Write live records to new file in background
3. Swap: Atomic KeyDir update to point to new file
4. Delete: Remove old file

**Benefits:**
- Eliminates fragmentation
- Reclaims space from deletions
- Does not block reads/writes
- Configurable thresholds

## Performance Characteristics

**Measured on:** Linux x86_64, SSD, Nim 2.2.6 (Release Build)

### Throughput
- **Write (None sync)**: ~250K ops/sec
- **Write (Sync)**: ~245K ops/sec
- **Write (Fsync)**: ~11.5K ops/sec
- **Read**: ~180K ops/sec
- **Mixed (80% read)**: ~278K ops/sec

### Latency
- **Write (None/Sync)**: ~0.004ms
- **Write (Fsync)**: ~0.086ms
- **Read**: ~0.006ms

### Resource Usage
- **Memory per key**: ~50 bytes (KeyDir overhead)
- **Recovery speed**: 40K keys/sec (with hint files)
- **Dataset size**: Limited only by disk space (bmRanged mode)

### CRC32 Options
Two implementations available:
- **Original** (default): Lookup table, ~600 ops/sec writes
- **Crunchy** (SIMD): `-d:useCrunchy` flag, currently slower for this workload

## Configuration

Key configuration options:

```nim
var cfg = defaultBarrelConfig()

cfg.mode = BarrelMode.bmNormal      # Or bmCritBit, bmRanged
cfg.syncMode = UserSyncMode.None    # Or Sync, Fsync
cfg.writeBufferSize = 64 * 1024     # 64KB buffer
cfg.autoCompact = true              # Enable background merge
cfg.compactThreshold = 0.3          # 30% fragmentation trigger
cfg.validateCrc = true              # Verify CRC32 on reads
cfg.defaultTtl = 0                  # Optional TTL in seconds
```

## Thread Safety

All operations are thread-safe using fine-grained locking:

- **KeyDir**: Lock-protected updates, lock-free reads
- **DataFile**: Per-file locks for I/O operations
- **WriteBuffer**: Lock + condition variable coordination
- **Merge**: Background thread with atomic swaps

Thread-safe usage example:
```nim
parallel:
  for i in 0..999:
    discard db.set(fmt"key:{i}", fmt"value:{i}")
```

## Key Features

### Implemented Features ✅
- ✅ Append-only storage with O(1) reads
- ✅ Three barrel modes (Normal, CritBit, Ranged)
- ✅ Range queries and prefix searches
- ✅ CRC32 data integrity verification
- ✅ Crash recovery with hint files (40K keys/sec)
- ✅ Background merge and compaction
- ✅ Configurable durability (None/Sync/Fsync)
- ✅ Write buffering and read-ahead caching
- ✅ Thread-safe concurrent operations
- ✅ LZ4 and Snappy compression support
- ✅ TTL support for automatic expiration

## Use Cases

### When to Use BitBarrel

**Perfect fit:**
- Session storage (fast, simple lookups)
- Caching layers (disk-backed, larger than RAM)
- Time-series data (ordered traversal with bmCritBit)
- Analytics data (billions of keys with bmRanged)
- Configuration storage (persistent, reliable)
- High-frequency counters (append-only efficiency)

**Not ideal:**
- Complex queries requiring joins
- Relational data with foreign keys
- Full-text search needs
- Multi-document transactions
- Graph data with relationships

## File Organization

```
src/
├── bitbarrel.nim              # Library entry point
├── bitbarrel/
│   ├── barrel.nim       # High-level Barrel API
│   ├── types.nim        # Common types and constants
│   └── config.nim       # Configuration management
└── storage/
    ├── datafile.nim     # Data file I/O
    ├── keydir.nim       # In-memory index
    ├── record.nim       # Record encoding/decoding
    ├── merge.nim        # Background compaction
    ├── recovery.nim     # Crash recovery engine
    ├── hintfile.nim     # Fast recovery metadata
    └── writebuffer.nim  # Write buffering with sync modes
```

## Comparison: BitBarrel vs Original Bitcask

BitBarrel enhances the classic Bitcask model:

| Feature | Original Bitcask | BitBarrel |
|---------|------------------|-----------|
| Index Type | Single hash table | Three modes (Hash/CritBit/Ranged) |
| Query Types | Simple GET/SET | + Range, Prefix, Ordered queries |
| Memory Limit | All keys in RAM | bmRanged supports >RAM datasets |
| Durability | Basic sync | Three sync modes + write buffering |
| Recovery | Slow scan | Fast with hint files (40K/sec) |
| Compression | None | LZ4 & Snappy support |
| TTL | No | Yes, with passive expiration |

## Trade-offs

### Strengths
- **Simplicity**: Easy to understand and maintain
- **Performance**: Excellent for simple KV operations
- **Predictability**: No query planning or garbage collection pauses
- **Resource efficiency**: Low memory usage, disk-backed
- **Reliability**: Append-only writes are inherently crash-safe

### Limitations
- **Memory**: KeyDir requires RAM (practical limit with bmNormal: 100M keys)
- **Write amplification**: Append-only creates overhead (mitigated by merge)
- **Single writer**: One write queue limits parallelism
- **No multi-key transactions**: Each operation is atomic
- **Single-node**: No built-in clustering (future enhancement)

## Future Considerations

Potential enhancements (see TODO.md):
- Network server with binary protocol
- Multi-key transaction support
- Replication and clustering
- Advanced monitoring and metrics
- Additional compression algorithms
- Secondary indexes

## References

- Bitcask: A Log-Structured Hash Table for Fast Key/Value Storage
- Original paper: http://basho.com/wp-content/uploads/2015/05/bitcask-intro.pdf
- Nim language: https://nim-lang.org/
