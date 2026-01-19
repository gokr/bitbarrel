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
   - `compact.nim` - Background compaction for space reclamation
   - `recovery.nim` - Crash recovery with hint file support
   - `hintfile.nim` - Fast recovery metadata files (v2 with incremental recovery)
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

### bmHash: Hash Table Mode (Default)
- Uses `Table[string, KeyDirEntry]` for O(1) lookups
- Simple hash map, no ordering guarantees
- Memory overhead: ~40 bytes per key
- Best for: General-purpose KV, caching, session storage

### bmCritBit: Sorted Mode
- Uses CritBitTree to maintain keys in sorted order
- Enables range queries and prefix searches
- Memory: All keys kept in sorted tree structure
- Best for: Time-series data, leaderboards, ordered traversal

### bmHugeCritBit: Two-Tier Mode
- Two-tier design for billion-key datasets
- Automatic range splitting and management
- Supports range queries with lazy loading
- Best for: Massive datasets, limited RAM, ordered access patterns
- **Status**: Partially implemented with separate API (`openHugeBarrel()` from `storage/hugebarrel` module)
- Network server supports HugeBarrel transparently via standard `createBarrel` command

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
   - ~188K ops/sec
   - Data loss on crash acceptable (caching)

2. **Sync**: OS-level durability
   - ~186K ops/sec
   - Data synced to OS buffers
   - Safe from app crashes, not power loss

3. **Fsync**: Full disk-level durability
   - ~9.1K ops/sec
   - Each write waits for disk confirmation
   - Safe from power loss

## Compaction

Background process reclaims space from deleted/overwritten records:

**Trigger Conditions:**
- Deleted records exceed 30% of file
- Total space overhead exceeds 50%
- Manual trigger via API

**Non-Blocking Compaction Process:**

BitBarrel uses a dual-file approach for truly non-blocking compaction:

1. **Start**: Create new file, write compaction marker for crash recovery
2. **Dual-file mode**:
   - Old file: read-only, being compacted
   - New file: receives ALL new writes AND compacted records
3. **Shadowing**: If a key is written during compaction, the new write overwrites the compacted entry via timestamp comparison
4. **Complete**: Delete old file, remove marker, generate hint file

```
Normal State:
  activeFile: 000001.data (read/write)

During Compaction (background thread):
  oldFile: 000001.data (read-only, being compacted)
  newFile: 000002.data (all new writes + compacted records)

After Compaction:
  activeFile: 000002.data (read/write)
  000001.data: deleted
```

**Crash Recovery:**
- Compaction marker file (.compacting) tracks in-progress compaction
- On startup, if marker exists: rebuild KeyDir from both files, delete old
- Ensures data integrity even with crashes during compaction

**Benefits:**
- Truly non-blocking: writes continue during compaction
- No temporary files: direct-to-target writing
- Automatic shadowing: KeyDir timestamp comparison handles overwrites
- Crash-safe: marker file ensures recovery from any failure point
- Configurable thresholds

## Performance Characteristics

**Measured on:** Linux x86_64, SSD, Nim 2.2.6 (Release Build), ThinkPad Carbon X1

### Throughput (Current Results, None sync mode)
- **Write**: ~188K ops/sec (10K records)
- **Read (random)**: ~172K ops/sec
- **Read (sequential)**: ~172K ops/sec
- **Mixed (80% read)**: ~137K ops/sec

*Performance varies significantly by sync mode and configuration. See `nimble bench` for current benchmarks.*

### Latency (Current Results)
- **Write**: ~0.005 ms per operation (None sync)
- **Read (random)**: ~0.006 ms per operation
- *Latency depends on sync mode, buffer size, and workload*

### Resource Usage
- **Memory per key**: ~40 bytes (KeyDir overhead)
- **Recovery speed**: 68K+ keys/sec (with hint files)
- **Dataset size**: Limited by available RAM for active keys (all keys must be in KeyDir)

### CRC32 Options
Two implementations available:
- **Original** (default): Lookup table, ~600 ops/sec writes
- **Crunchy** (SIMD): `-d:useCrunchy` flag, currently slower for this workload

## Configuration

Key configuration options:

```nim
var cfg = defaultBarrelConfig()

cfg.mode = BarrelMode.bmHash        # Or bmCritBit
cfg.syncMode = UserSyncMode.None    # Or Sync, Fsync
cfg.writeBufferSize = 64 * 1024     # 64KB buffer
cfg.autoCompact = true              # Enable background compaction
cfg.compactThreshold = 0.3          # 30% fragmentation trigger
cfg.validateCrc = true              # Verify CRC32 on reads
cfg.defaultTtl = 0                  # Optional TTL in seconds
```

## Thread Safety

All operations are thread-safe using fine-grained locking:

- **KeyDir**: Lock-protected updates, lock-free reads
- **DataFile**: Per-file locks for I/O operations
- **WriteBuffer**: Lock + condition variable coordination
- **Compaction**: Background thread with dual-file approach (writes continue during compaction)

Thread-safe usage example:
```nim
parallel:
  for i in 0..999:
    discard db.set(fmt"key:{i}", fmt"value:{i}")
```

### ORC Crash Prevention Patterns

BitBarrel uses specific patterns to prevent crashes with Nim's ORC garbage collector, particularly in threaded code with cross-thread references.

#### Background
Nim's ORC garbage collector can crash during thread shutdown when detecting cycles across thread boundaries. This affects threaded code using closures that capture references.

#### Solution Patterns

**1. Mark types as `{.acyclic.}`**

Types involved in cross-thread references are marked with `{.acyclic.}` to prevent ORC cycle detection:
```nim
type
  BarrelObj {.acyclic.} = object
    # ... fields including compactController: CompactController

  CompactControllerObj {.acyclic.} = object
    # ... raw pointers instead of closures

  HistoryStoreObj {.acyclic.} = object
    # ... used in pub/sub system

  PubSubManagerObj {.acyclic.} = object
    # ... used in network layer
```

**2. Eliminate closures in cross-thread code**

Instead of closures that capture references (which create GC-managed environments), store raw pointers directly:

```nim
# BAD - closures cause ORC crashes in threaded code
proc newCompactController(keyDir: ptr KeyDir): CompactController =
  proc updateCallback(key: string, entry: KeyDirEntry) {.gcsafe.} =
    keyDir[].add(key, entry)  # Closure captures keyDir
  result.updateEntry = updateCallback  # ORC tracks closure environment

# GOOD - direct pointer storage, no closures
type
  IndexMode = enum
    imNone, imKeyDir, imCritBit

  CompactControllerObj = object
    indexMode: IndexMode
    keyDirPtr: pointer    # Raw pointer, not tracked by ORC
    critBitPtr: pointer

proc updateIndex(controller: CompactController, key: string, entry: KeyDirEntry) =
  case controller.indexMode
  of imKeyDir:
    cast[ptr KeyDir](controller.keyDirPtr)[].add(key, entry)
  # ...
```

**3. Cleanup order matters**

Shutdown controllers BEFORE deinitializing resources they reference:

```nim
proc close*(barrel: Barrel) =
  # Wait for threads to complete
  while barrel.compactionState.inProgress:
    sleep(10)
  barrel.joinCompactionThread()

  # Shutdown controller BEFORE deinit - it holds pointers to these
  if barrel.compactController != nil:
    barrel.compactController.shutdown()
    barrel.compactController = nil

  # Now safe to deinit
  barrel.keyDir.deinit()
```

#### When to apply these patterns

- **Use `{.acyclic.}`**: On ref object types involved in cross-thread patterns
- **Eliminate closures**: When callbacks/procs need to access data across threads
- **Use raw pointers**: Instead of closures that capture references
- **Explicit cleanup**: Shutdown controllers before deinitializing referenced resources

#### Affected components

The following components use these patterns to prevent ORC crashes:

1. **Compaction system** (`src/storage/compact.nim`):
   - `CompactControllerObj` marked `{.acyclic.}`
   - Stores raw `keyDirPtr` and `critBitPtr` instead of closures
   - Background worker thread with cross-thread references

2. **Pub/Sub system** (`src/pubsub/`):
   - `HistoryStoreObj`, `EventBrokerObj`, `PubSubManagerObj`, `PresenceManagerObj` all marked `{.acyclic.}`
   - Network thread integration requires cycle prevention

3. **Network layer** (`src/network/`):
   - WebSocket worker pool with cross-thread object references
   - `{.acyclic.}` types prevent ORC crashes during thread shutdown

#### References

See actual implementation in:
- `src/storage/compact.nim:22` - CompactControllerObj with `{.acyclic.}` and raw pointers
- `src/bitbarrel/barrel.nim:37` - BarrelObj marked `{.acyclic.}`
- `src/pubsub/history.nim:16` - HistoryStoreObj marked `{.acyclic.}`

These patterns ensure all threaded tests pass without ORC crashes.

## Key Features

### Implemented Features ✅
- ✅ Append-only storage with O(1) reads
- ✅ Three barrel modes (Normal, CritBit, Ranged)
- ✅ Range queries and prefix searches
- ✅ CRC32 data integrity verification
- ✅ Crash recovery with hint files (68K+ keys/sec)
- ✅ Non-blocking background compaction (writes continue during compaction)
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
- Analytics data (see research/HUGECRITBIT.md for billion-key design)
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
    ├── compact.nim      # Background compaction
    ├── recovery.nim     # Crash recovery engine
    ├── hintfile.nim     # Fast recovery metadata
    └── writebuffer.nim  # Write buffering with sync modes
```

## Comparison: BitBarrel vs Original Bitcask

BitBarrel enhances the classic Bitcask model:

| Feature | Original Bitcask | BitBarrel |
|---------|------------------|-----------|
| Index Type | Single hash table | Two modes (Hash/CritBit) |
| Query Types | Simple GET/SET | + Range, Prefix, Ordered queries (CritBit) |
| Memory Limit | All keys in RAM | All keys in RAM (see research/HUGECRITBIT.md for >RAM design) |
| Durability | Basic sync | Three sync modes + write buffering |
| Recovery | Slow scan | Fast with hint files (68K+/sec) |
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
- **Memory**: KeyDir requires RAM (practical limit with bmHash: 100M keys)
- **Write amplification**: Append-only creates overhead (mitigated by compaction)
- **Single writer**: One write queue limits parallelism
- **No multi-key transactions**: Each operation is atomic
- **Single-node**: No built-in clustering (future enhancement)

## Pub/Sub System

BitBarrel includes a comprehensive Pub/Sub (Publish/Subscribe) messaging system with multiple storage backends.

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│           BitBarrel Server                              │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │          PubSubManager                           │  │
│  │  - Subscriptions management                      │  │
│  │  - Pattern matching (glob: *)                    │  │
│  │  - Presence tracking                             │  │
│  └────────────┬─────────────────────────────────────┘  │
│               │                                         │
│  ┌────────────▼─────────────────────────────────────┐  │
│  │        HistoryStoreV2                            │  │
│  │  - Message history API                           │  │
│  │  - Sequence numbering                            │  │
│  └────────────┬─────────────────────────────────────┘  │
│               │                                         │
│  ┌────────────▼─────────────────────────────────────┐  │
│  │      StorageManager                              │  │
│  │  - Topic → Backend routing                       │  │
│  │  - Pattern-based configuration                   │  │
│  │  - Lifecycle management                          │  │
│  └────────┬──────────────────┬──────────────────┬───┘  │
│           │                  │                  │      │
│  ┌────────▼──┐        ┌─────▼────┐      ┌────▼───┐  │
│  │  Memory   │        │  Shared  │      │ Per-   │  │
│  │  Backend  │        │  Barrel  │      │ Topic  │  │
│  │           │        │  Backend │      │ Barrel │  │
│  └───────────┘        └──────────┘      └────────┘  │
└─────────────────────────────────────────────────────────┘
```

### Components

1. **PubSubManager** (`src/pubsub.nim`)
   - Manages client subscriptions
   - Handles pattern matching (`topic:*`)
   - Publishes messages to subscribers
   - Tracks presence information

2. **HistoryStoreV2** (`src/pubsub/history_v2.nim`)
   - High-level API for message history
   - Automatic sequence numbering
   - Integration with storage backends

3. **StorageManager** (`src/pubsub/storage_manager.nim`)
   - Routes topics to appropriate backends
   - Lazy backend initialization
   - Idle backend cleanup
   - Pattern-based configuration

4. **Storage Backends**
   - **MemoryBackend** - Fast, volatile ring buffer
   - **SharedBarrelBackend** - Persistent, all topics in one barrel
   - **PerTopicBarrelBackend** - Isolated, one barrel per topic

### Storage Configuration

```nim
var config = initStorageConfig()
config.defaultStrategy = ssSharedBarrel  # Persistent by default

// Memory-only for chat (ephemeral)
var chatConfig = TopicStorageConfig(strategy: ssMemoryOnly)
config.addTopicOverride("chat:*", chatConfig)

// Per-topic for user notifications
var userConfig = TopicStorageConfig(strategy: ssPerTopicBarrel)
config.addTopicOverride("user:*:notifications", userConfig)
```

**See full documentation:**
- [Pub/Sub User Guide](../USER_GUIDE/pubsub.md)
- [Storage Backends Deep Dive](../FEATURES/pubsub-storage.md)

## Query Result Plugin System

BitBarrel provides an extensible hook system for transforming query results dynamically.

### Plugin Architecture

```
Client Query → Barrel API → Storage Layer → Query Results
                                      ↓
                               Apply Plugins
                                      ↓
                          ┌──────────▼──────────┐
                          │  Plugin Registry    │
                          │  - Range hooks    │
                          │  - Prefix hooks   │
                          └──────────┬──────────┘
                                     │
                 ┌───────────────────┼───────────────────┐
                 │                   │                   │
         ┌───────▼──────┐   ┌────────▼────────┐  ┌──────▼──────┐
         │ Filter Items │   │ Transform Items │  │ Limit Count │
         │              │   │                 │  │             │
         └──────────────┘   └─────────────────┘  └─────────────┘
                                     │
                                     ▼
                          Return Transformed Results
```

### Creating a Plugin

```nim
import hooks/query_result_hooks

proc myFilter(metadata: HookMetadata,
              items: var seq[(string, string)],
              nextCursor: var string,
              hasMore: var bool) =
  items.keepItIf(it[1].contains("active"))

let pluginId = registerPlugin(
  "activeOnly",     # Plugin name
  myFilter,         # Plugin procedure
  hkRangeQuery,     # Hook type
  "Filter to active items"  # Description
)
```

### Using Plugins

```nim
// In queries
let (items, cursor, hasMore) = barrel.itemsInRange(
  startKey = "user:1000",
  endKey = "user:2000",
  limit = 100,
  cursor = "",
  hooks = @["activeOnly"]  // Apply hook
)

// Multiple hooks
let hooks = @["filter1", "transform", "limit"]
```

**See full documentation:**
- [Query Plugins Feature Guide](../FEATURES/hooks.md)
- [Plugin Tests](../../tests/plugins/test_query_result_hooks.nim)

## Network Protocol & Server

BitBarrel includes a complete network server with WebSocket-based Pub/Sub support.

### Protocol Stack

```
┌─────────────────────────────────────────┐
│          WebSocket Layer                │
│  - Binary protocol                      │
│  - Frame-based messaging                │
├─────────────────────────────────────────┤
│       BitBarrel Protocol                │
│  - CRUD operations (GET, SET, etc.)     │
│  - Barrel management (CREATE, DROP)     │
│  - Queries (RANGE, PREFIX)              │
│  - Pub/Sub (SUBSCRIBE, PUBLISH)         │
├─────────────────────────────────────────┤
│       Network Client Library            │
│  - Nim, Go, Python, TypeScript, Dart    │
└─────────────────────────────────────────┘
```

### Network Architecture

**Server Components:**
- **Protocol Handler** - Request/response handling
- **Auth Middleware** - JWT-based authentication
- **Pub/Sub Manager** - Real-time messaging
- **Storage Backends** - Persistent message history

**Client Features:**
- Full CRUD operations with auth support
- Range and prefix queries
- Pub/Sub with pattern matching
- Presence tracking
- Cursor-based pagination

### Client Language Support

| Feature | Nim | Go | Python | TypeScript | Dart |
|---------|-----|----|--------|------------|------|
| CRUD ops | ✅ | ✅ | ✅ | ✅ | ✅ |
| Range queries | ✅ | ✅ | ✅ | ✅ | ✅ |
| Pub/Sub | ✅ | ✅ | ✅ | ✅ | ✅ |
| Auth (JWT) | ✅ | ✅ | ✅ | ✅ | ✅ |

**See documentation:**
- [Network Client Guide](../networking-guide.md)
- [Protocol Specification](../PROTOCOL.md)
- [Network Architecture](../network-architecture.md)

## Key Features (Updated)

### Implemented Features ✅
- ✅ Append-only storage with O(1) reads
- ✅ Three barrel modes (bmHash, bmCritBit, bmHugeCritBit)
- ✅ Range queries and prefix searches
- ✅ CRC32 data integrity verification
- ✅ Crash recovery with hint files (68K+ keys/sec)
- ✅ Non-blocking background compaction
- ✅ Configurable durability (None/Sync/Fsync)
- ✅ Write buffering and read-ahead caching
- ✅ Thread-safe concurrent operations
- ✅ LZ4 and Snappy compression support
- ✅ TTL support for automatic expiration
- ✅ **Network server with binary protocol**
- ✅ **Pub/Sub message system** with pattern matching
- ✅ **Pluggable storage backends** for message history
- ✅ **Query result plugins** for dynamic transformation
- ✅ **JWT authentication** with RBAC
- ✅ **Multi-language client libraries** (Nim, Go, Python, TypeScript, Dart)

## Comparison: BitBarrel vs Original Bitcask

```
+--------------------------------+---------------+-------------+
| Feature                        | Bitcask       | BitBarrel   |
+--------------------------------+---------------+-------------+
| Index Type                     | Single hash   | Three modes |
| Query Types                    | GET/SET       | + Range/Prefix/PubSub |
| Memory Limit                   | All keys RAM  | All keys RAM |
| Durability                     | Basic sync    | Three modes + buffering |
| Recovery                       | Slow scan     | 68K+/sec with hints |
| Compression                    | None          | LZ4/Snappy |
| Network Protocol               | None          | Full binary + Pub/Sub |
| Storage Backends               | Simple file   | Pluggable (memory/persistent) |
| Query Plugins                  | None          | Transform results |
| Client Libraries               | None          | 5 languages |
+--------------------------------+---------------+-------------+
```

## File Organization

```
src/
├── bitbarrel.nim              # Library entry point
├── bitbarrel/
│   ├── barrel.nim       # High-level Barrel API
│   ├── lowlevelapi.nim  # Direct storage access
│   ├── types.nim        # Common types
│   └── config.nim       # Configuration
├── storage/              # Storage engine
│   ├── datafile.nim     # Data file I/O
│   ├── keydir.nim       # In-memory index
│   ├── record.nim       # Record encoding
│   ├── compact.nim      # Compaction
│   ├── recovery.nim     # Crash recovery
│   ├── hintfile.nim     # Fast recovery metadata
│   ├── writebuffer.nim  # Write buffering
│   └── readbuffer.nim   # Read caching
├── pubsub/               # Pub/Sub system
│   ├── pubsub.nim       # Main Pub/Sub manager
│   ├── history_v2.nim   # Message history API
│   ├── storage_backend.nim # StorageBackend interface
│   ├── memory_backend.nim  # In-memory backend
│   ├── shared_barrel_backend.nim # Shared barrel backend
│   ├── storage_config.nim  # Configuration system
│   └── storage_manager.nim # Backend lifecycle
├── plugins/              # Plugin system
│   └── query_result_hooks.nim # Query transformation
└── network/              # Network layer
    ├── server.nim       # BitBarrel server
    ├── protocol.nim     # Protocol handler
    └── client/          # Client libraries
        ├── nim/         # Nim client
        ├── go/          # Go client
        ├── python/      # Python client
        ├── typescript/  # TypeScript client
        └── dart/        # Dart client
```

## Future Considerations

Potential enhancements:
- Multi-key transaction support
- Replication and clustering
- Advanced monitoring and metrics
- Additional compression algorithms
- Secondary indexes
- Tiered storage (hot/cold data)
- Stream processing integration
- Graph query extensions

## References

- Bitcask: A Log-Structured Hash Table for Fast Key/Value Storage
- Original paper: http://basho.com/wp-content/uploads/2015/05/bitcask-intro.pdf
- Nim language: https://nim-lang.org/
- Pub/Sub protocols: MQTT, AMQP, Redis Pub/Sub

## Feature Documentation

Detailed documentation for individual features:

- [Hint Files](../FEATURES/hint-files.md) - Metadata files for fast recovery (68K+ keys/sec)
- [Read-Ahead LRU Buffering](../FEATURES/read-buffering.md) - Caching with LRU eviction
- [Compression](../FEATURES/compression.md) - LZ4 and Snappy compression support
- [Data Integrity](../FEATURES/data-integrity.md) - CRC32 validation
- [Networking](../FEATURES/networking.md) - Network protocol and API
- [Query Plugins](../FEATURES/hooks.md) - Transform query results
- [Pub/Sub Storage](../FEATURES/pubsub-storage.md) - Pluggable storage backends

## References

- Bitcask: A Log-Structured Hash Table for Fast Key/Value Storage
- Original paper: http://basho.com/wp-content/uploads/2015/05/bitcask-intro.pdf
- Nim language: https://nim-lang.org/
