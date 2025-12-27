# BitBarrel Tutorial: High-Performance Key-Value Store

This tutorial walks you through using the Bitcask-style key-value store (BitBarrel) implementation in Nim. By the end, you'll understand how to use the storage engine, run benchmarks, and stress-test the system.

## Key Features

BitBarrel provides these core capabilities:

- **Three Index Modes**: Choose from hash table (O(1)), CritBit tree (ordered), or lazy-loaded partitions
- **Range Queries**: Prefix searches and range scans (CritBit mode)
- **Fast Recovery**: Hint files enable ultra-fast recovery (up to 10x faster)
- **Non-Blocking Compaction**: Writes continue during background compaction
- **Read Buffering**: LRU cache for improved read performance
- **Write Buffering**: Configurable sync modes for different durability needs
- **Thread Safety**: Concurrent access support with proper locking
- **Data Integrity**: CRC32 checksums for all records

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Building the Project](#building-the-project)
3. [Basic Concepts](#basic-concepts)
4. [Running Demos](#running-demos)
5. [Benchmarking](#benchmarking)
6. [Stress Testing](#stress-testing)
7. [Understanding Performance](#understanding-performance)
8. [Advanced Usage](#advanced-usage)

## Prerequisites

- Nim >= 2.0 installed
- Basic understanding of key-value stores
- (Optional) For best performance: NVMe SSD, 4+ CPU cores

## Building the Project

### Compile Nimble Package

```bash
cd path/to/bitbarrel
nimble build
```

This builds the library and makes all modules available for import.

### Run Tests

Before running demos, verify everything works:

```bash
# Run all tests
nimble test

# Or run individual test suites
nim c -r tests/test_storage.nim
nim c -r tests/test_keydir.nim
nim c -r tests/test_integration.nim
nim c -r tests/recovery/test_compact.nim  # Compaction tests
nim c -r tests/test_hintfile.nim   # Hint file tests
nim c -r tests/test_recovery.nim   # Recovery with hint support
```

Expected output: All tests should pass ✓

## Basic Concepts

### Bitcask Architecture

This BitBarrel uses the Bitcask storage model:

```
┌─────────────────────────────────────────┐
│ Data File (*.data)                      │
├─────────────────────────────────────────┤
│ [Header: 32 bytes]                      │
│ [Record 1] CRC32 + Data + Key + Value   │
│ [Record 2] CRC32 + Data + Key + Value   │
│ ...                                       │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│ KeyDir (In-Memory Index)                │
├─────────────────────────────────────────┤
│ Key → {fileId, position, size, ts}     │
└─────────────────────────────────────────┘
```

**Key Features:**
- **Append-only writes**: Fast sequential I/O
- **In-memory index**: O(1) lookups
- **CRC32 checksums**: Data integrity
- **Crash recovery**: Hint files for ultra-fast startup (<10ms for small datasets)

### Core Components

1. **DataFile**: Handles reading/writing to disk
2. **KeyDir**: Thread-safe in-memory hash index
3. **Record**: Encodes/decodes key-value pairs
4. **Compaction**: Background compaction for space reclamation
5. **HintFile**: Binary format for fast recovery
6. **Write Buffer**: Configurable write batching
7. **Read Buffer**: LRU cache for hot data

## Running Demos

### Basic Demo (examples/basic_demo.nim)

Demonstrates CRUD operations:

```bash
nim c -r examples/basic_demo.nim
```

**What it does:**
- Creates a database
- Stores 3 user records
- Reads them back
- Updates a record
- Deletes a record (using tombstone)
- Shows final statistics

**Expected output:**
```
╔════════════════════════════════════════════════════════════╗
║   BitBarrel Demo: Basic CRUD Operations                         ║
╚════════════════════════════════════════════════════════════╝

📁 Opening database...

✍️  Storing user data...
   SET user:1 = Alice Johnson
   SET user:2 = Bob Smith
   SET user:3 = Charlie Brown

📖 Reading user data...
   ✅ GET user:1 = Alice Johnson
   ✅ GET user:2 = Bob Smith
   ✅ GET user:3 = Charlie Brown

🔄 Updating user:1...
   SET user:1 = Alice Smith-Johnson
   ✅ Verified: user:1 = Alice Smith-Johnson

🗑️  Deleting user:2...
   SET user:2 = (tombstone)
   ✅ Verified: user:2 is deleted (tombstone)

✨ Demo completed successfully!
   Total keys in database: 3
```

### Original Demo (examples/demo.nim)

More detailed demonstration with file statistics:

```bash
nim c -r examples/demo.nim
```

## Benchmarking

### Simple Benchmark (bench/simple_bench.nim)

Comprehensive performance testing:

```bash
# Compile with release mode for accurate results
nim c -d:release bench/simple_bench.nim

# Run the benchmark
./bench/simple_bench
```

**What it measures:**
- Write throughput (sequential)
- Read throughput (sequential)
- Read throughput (random)
- Mixed workload (80% reads, 20% writes)

**Interpreting Results:**

Example output:
```
╔════════════════════════════════════════════════════════════╗
║ System Information                                        ║
╚════════════════════════════════════════════════════════════╝
  Nim version: 2.0.0
  Build: 2025-12-07 01:23:45
  OS: linux
  CPU: amd64
  Optimization: Release
  GC: ARC/ORC

╔════════════════════════════════════════════════════════════╗
║ Write Benchmark                                           ║
╚════════════════════════════════════════════════════════════╝
  Records to write: 10_000
  ✓ Completed in 0.107 seconds
  ✓ Throughput: 93,458 ops/sec
  ✓ Data rate: 8.45 MiB/sec
  ✓ Avg latency: 0.010 ms per op
```

**Target Performance:**
- **Current**: ~90K writes/sec, ~110K reads/sec
- **With buffering**: 50K-100K writes/sec (fsync), 100K+ reads/sec
- **Latency**: < 1ms for cached reads, < 0.5ms for writes

### Running Benchmarks with Nimble

```bash
# Using nimble task (if configured)
nimble bench

# Or manually
nim c -d:release bench/simple_bench.nim && ./bench/simple_bench
```

## Stress Testing

### Stress Test Suite (bench/stress_test.nim)

Pushes the system to its limits:

```bash
nim c -d:release bench/stress_test.nim
./bench/stress_test
```

**Tests Included:**

1. **Large Keys**: Keys at maximum size (64KB)
2. **Large Values**: Values up to 32MB
3. **Rapid Writes**: 5K sequential writes as fast as possible
4. **Random Access**: Mixed reads/writes with 70/30 ratio
5. **Memory Usage**: 25K keys to measure overhead

**Expected Output:**
```
╔════════════════════════════════════════════════════════════╗
║ BitBarrel Stress Test Suite                                     ║
╚════════════════════════════════════════════════════════════╝
  Testing system limits and error handling...

╔════════════════════════════════════════════════════════════╗
║ Testing Maximum Key Size                                  ║
╚════════════════════════════════════════════════════════════╝
  Testing key of max size (64KB)...
  ✅ Max key test passed

  Testing keys of various sizes...
  ✅ Various key sizes test completed
  Total entries: 7
```

**Key Metrics to Watch:**
- Throughput under load
- Error rates (should be 0)
- Memory consumption
- File size growth

## Understanding Performance

### Current Performance Characteristics

Without optimizations (current implementation):
```
Write throughput: ~90K ops/sec
Read throughput:  ~110K ops/sec
Avg write latency: ~0.01 ms
Avg read latency:  ~0.009 ms
```

**Note**: Each write flushes immediately, which limits throughput. With write buffering, expect 5-10x improvement.

### Performance Tips

1. **Use release builds**: `-d:release` enables optimizations
2. **Enable CPU performance mode**: `sudo cpupower frequency-set -g performance`
3. **Use fast storage**: NVMe SSDs show 2-3x improvement over SATA SSDs
4. **Batch operations**: Group writes when possible (especially for remote clients)
5. **Adjust write buffering**: Tune buffer size and sync frequency for your workload
6. **Enable compression**: For values >256 bytes, compression reduces I/O by 30-50%

### Compression

BitBarrel supports transparent compression of record values to reduce storage and I/O overhead:

#### Supported Algorithms
- **LZ4** (recommended): ~500 MB/s compression, 2.1x compression ratio
- **Snappy**: ~250 MB/s compression, 1.7x compression ratio, more robust error handling

#### Building with Compression

```bash
# Build with LZ4 compression
nim c -d:lz4Compression -d:release src/bitbarrel.nim

# Build with Snappy compression
nim c -d:snappyCompression -d:release src/bitbarrel.nim

# Or use nimble tasks:
nimble buildLz4    # For LZ4
nimble buildSnappy # For Snappy
```

#### Configuration

Enable compression in your configuration file:

```yaml
storage:
  compression:
    enabled: true      # Enable/disable
    threshold: 256      # Min size to compress (bytes)
    level: "default"    # "fast", "default", or "best"
```

#### When to Use Compression

- **Good for**: Text, JSON, logs, documents, repeated patterns
- **Avoid**: Already compressed data (JPEG, MP3), very small values (<256 bytes)
- **Impact**: +5-10ms write overhead, 30-50% space savings on compressible data

### Performance Characteristics

**Current Optimizations:**
1. Write buffering: Configurable batching reduces I/O overhead
2. Read-ahead buffering: LRU cache for frequently accessed data
3. Hint files: Fast recovery from crashes
4. Background compaction: Automatic space reclamation without blocking
5. Optional compression: Reduces I/O and storage for large values

**Implementation Features:**
1. Thread-safe operations with proper locking
2. CRC32 checksums for data integrity
3. Configurable sync modes for different durability requirements
4. Automatic file rotation at configurable size limits

**Areas for Future Enhancement:**
1. Network protocol for remote access
2. Additional performance tuning options
3. Async I/O for network operations

## Library Usage

### High-Level API (Recommended)

The high-level API provides a simple interface for most use cases:

```nim
import bitbarrel

# Basic usage
var db = openBarrel("mydb")
db.set("user:1", "Alice")
db.set("user:2", "Bob")
echo db.get("user:1")  # "Alice"
echo db.count()         # 2
db.close()
```

### Configuration Options

The high-level API supports several configuration options:

```nim
import bitbarrel
from bitbarrel/config import UserSyncMode

# Create custom configuration
var cfg = defaultBarrelConfig()
cfg.writeBufferSize = 1024 * 1024  # 1MB write buffer
cfg.syncMode = UserSyncMode.Fsync   # Force fsync on writes
cfg.autoCompact = true
cfg.compactThreshold = 0.3  # Compact when 30% are deletions

# Open database with custom config
var db = openBarrel("mykv", cfg)

# Use the database normally
db.set("test", "value")
db.delete("old_key")
db.close()
```

#### Sync Modes

- **UserSyncMode.None**: No explicit sync (fastest, potential data loss)
- **UserSyncMode.Sync**: Sync to OS buffer cache (default)
- **UserSyncMode.Fsync**: Force disk sync (safest, slowest)

### Simple Operations

```nim
import bitbarrel

var db = openBarrel("mydb")

# Basic CRUD
db.set("key", "value")           # Returns bool for success
let value = db.get("key")        # Returns "" if not found
let exists = db.exists("key")    # Returns bool

# Delete with tombstone
db.delete("key")

# Get all keys
let allKeys = db.listKeys()

# Clear all keys (in-memory only)
db.clear()

# Check if database is closed
echo db.isClosed()  # false

db.close()
```

### Barrel Modes

BitBarrel provides three different index modes to optimize for different use cases. Each mode has different performance characteristics and memory requirements.

#### bmHash Mode (Default)

The default mode uses a hash table for O(1) lookups. This is ideal for simple key-value operations where key ordering is not needed.

**Key characteristics:**
- **Lookup**: O(1) time complexity
- **Memory**: ~50 bytes per key
- **Ordering**: None - keys are not sorted

```nim
import bitbarrel
from bitbarrel/types import BarrelMode, BarrelConfig, defaultBarrelConfig

# Use default bmHash mode
var cfg = defaultBarrelConfig()
# cfg.mode is already bmHash by default

var db = openBarrel("myapp.db", cfg)
db.set("session:abc123", "user_data")
let data = db.get("session:abc123")
echo data  # "user_data"
```

**Best for**: Caching, session storage, general key-value operations

#### bmCritBit Mode

This mode uses a CritBit tree to keep all keys sorted in memory. It enables range queries and prefix searches.

**Key characteristics:**
- **Lookup**: O(k) where k is key length
- **Memory**: Similar to bmHash but with tree overhead
- **Ordering**: Keys are sorted lexicographically
- **Features**: Range queries, prefix searches, ordered iteration

```nim
import bitbarrel
from bitbarrel/types import BarrelMode, BarrelConfig, defaultBarrelConfig

# Configure for CritBit mode
var cfg = defaultBarrelConfig()
cfg.mode = BarrelMode.bmCritBit

var db = openBarrel("timeseries.db", cfg)

# Store timestamped data
db.set("2024-01-01:temp", "22.5")
db.set("2024-01-02:temp", "23.1")
db.set("2024-01-03:temp", "21.8")

# Range query: Get all temperature readings for January
let januaryData = db.keysInRange("2024-01-01", "2024-01-31")
for key in januaryData:
  echo key, " = ", db.get(key)

# Prefix search: Get all keys of type "temp"
let tempKeys = db.keysWithPrefix("2024-01-:temp")
echo "Temperature readings: ", tempKeys.len

# Count keys with prefix (faster than retrieving all keys)
let count = db.countWithPrefix("2024-01-")
echo "Total January records: ", count
```

**Best for**: Time-series data, leaderboards, ordered data, prefix matching

#### bmHugeCritBit Mode

This mode uses a two-tier design for datasets that are too large to fit in memory. It supports range queries with lazy-loaded partitions.

**Key characteristics:**
- **Lookup**: O(1) with range management overhead
- **Memory**: Configurable - only loaded ranges consume memory
- **Ranges**: Keys are distributed across multiple ranges with automatic splitting
- **Features**: Range queries, automatic range management, ordered iteration

```nim
import bitbarrel
from bitbarrel/types import BarrelMode, BarrelConfig, defaultBarrelConfig

# Configure for HugeCritBit mode
var cfg = defaultBarrelConfig()
cfg.mode = BarrelMode.bmHugeCritBit
cfg.hugeConfig.maxEntriesPerRange = 500_000  # 500K keys per range
cfg.hugeConfig.rangeCacheSize = 10            # Keep 10 ranges in memory

var db = openBarrel("analytics.db", cfg)

# Store millions/billions of keys
db.set("user:1:action:view", "product:12345")
db.set("user:999999:action:purchase", "product:67890")

# Range statistics
let stats = db.rangeStats()
echo "Total ranges: ", stats.total
echo "Loaded ranges: ", stats.loaded
echo "Total keys: ", stats.totalKeys

# Flush all loaded ranges to disk (useful before shutdown)
let flushed = db.flushAllRanges()
echo "Flushed ranges: ", flushed
```

**Best for**: Analytics data, user activity logs, large datasets with bursty access patterns, ordered data

## Advanced Usage

### Low-Level API

For fine-grained control, use the low-level API:

```nim
import bitbarrel/[lowlevelapi, barrel]

# Work directly with data files
var df = lowlevelapi.openDataFile("mydb.data", 1'u32)
var kd = lowlevelapi.withKeyDir:
  # Use KeyDir inside this block

# Helper functions
var entry = lowlevelapi.newKeyDirEntry(
  fileId = 1,
  recordPos = 100,
  valuePos = 150,
  valueSize = 20,
  timestamp = getTime().toUnix(),
  recordSize = 70
)

var info = lowlevelapi.newRecordInfo(
  recordPos = 100,
  valuePos = 150,
  valueSize = 20,
  recordSize = 70
)
```

### Custom Configuration (Low-Level)

```nim
import bitbarrel/types
import storage/datafile
import storage/keydir

# Configure file size limits
const
  MAX_FILE_SIZE = 100 * 1024 * 1024  # 100MB per file
  MAX_KEY_SIZE = 1024                # 1KB max key
  MAX_VALUE_SIZE = 10 * 1024 * 1024  # 10MB max value

# Create data file with custom sync mode
var dataFile = open("mydb_001.data", 1'u32,
                   syncMode = syncBuffered,
                   shouldFsync = true,
                   bufferSize = 64 * 1024)

# Initialize KeyDir
var keyDir = init()

# Custom error handling
try:
  let info = dataFile.appendRecord(key, value, timestamp)
  keyDir.add(key, KeyDirEntry(...))
except IOError as e:
  echo &"Write failed: {e.msg}"
except ValueError as e:
  echo &"Invalid data: {e.msg}"
```

### Working with Large Datasets

```nim
# Batch processing example
proc batchProcess(dataFile: var DataFile, keyDir: var KeyDir, entries: seq[(string, string)]) =
  const BATCH_SIZE = 1000

  for i in 0..<entries.len:
    let (key, value) = entries[i]
    let info = dataFile.appendRecord(key, value, getTime().toUnix())
    keyDir.add(key, KeyDirEntry(...))

    # Log progress
    if (i + 1) mod BATCH_SIZE == 0:
      echo &"Processed {i + 1}/{entries.len}..."

# Process 1 million entries
let entries = readDataFromSource()
batchProcess(dataFile, keyDir, entries)
```

### Monitoring and Debugging

```nim
# Get database statistics
proc getStats(dataFile: DataFile, keyDir: KeyDir) =
  let header = dataFile.readHeader()
  echo &"File size: {header.fileSize} bytes"
  echo &"Record count: {keyDir.len}"
  echo &"Keys in index: {keyDir.len}"

# Verify data integrity
proc verifyData(dataFile: DataFile, keyDir: var KeyDir) =
  var errors = 0
  for key in keyDir.keys():
    let found = keyDir.get(key)
    if found.isSome():
      let entry = found.get()
      let recordInfo = RecordInfo(...)
      try:
        let (k, v, _) = dataFile.readRecord(recordInfo)
        if k != key:
          errors.inc()
          echo &"Key mismatch: {key} != {k}"
      except:
        errors.inc()
        echo &"Failed to read: {key}"

  echo &"Verification complete, errors: {errors}"
```

### Custom Serialization

#### With High-Level API

```nim
import json
import bitbarrel

type
  User* = object
    name*: string
    email*: string
    age*: int

proc saveUser(db: Barrel, userId: string, user: User): bool =
  let jsonStr = $$user  # Quick JSON conversion
  return db.set("user:" & userId, jsonStr)

proc loadUser(db: Barrel, userId: string): Option[User] =
  let jsonStr = db.get("user:" & userId)
  if jsonStr.len > 0:
    try:
      let jsonNode = parseJson(jsonStr)
      result = some(User(
        name: jsonNode["name"].getStr(),
        email: jsonNode["email"].getStr(),
        age: jsonNode["age"].getInt()
      ))
    except:
      result = none(User)

# Usage
var db = openBarrel("users.db")
let user = User(name: "Alice", email: "alice@example.com", age: 30)
discard db.saveUser("12345", user)

let loaded = db.loadUser("12345")
if loaded.isSome():
  let u = loaded.get()
  echo &"User: {u.name}, {u.email}"
db.close()
```

#### With Low-Level API

```nim
import json
import bitbarrel/types
import storage/datafile
import storage/keydir

type
  User* = object
    name*: string
    email*: string
    age*: int

proc serializeUser(user: User): string =
  let jsonNode = %*{
    "name": user.name,
    "email": user.email,
    "age": user.age
  }
  return $jsonNode

proc deserializeUser(data: string): User =
  let jsonNode = parseJson(data)
  result.name = jsonNode["name"].getStr()
  result.email = jsonNode["email"].getStr()
  result.age = jsonNode["age"].getInt()

# Usage
let user = User(name: "Alice", email: "alice@example.com", age: 30)
let serialized = serializeUser(user)
dataFile.appendRecord("user:alice", serialized, timestamp)
```

### Performance Comparison: With and Without Optimizations

**Current Implementation (No Buffering):**
```
Writes: ~90K ops/sec
CPU usage: High (CRC32 bit-by-bit)
I/O: Flush per operation
```

**With Proposed Optimizations:**
```
Writes: ~500K ops/sec (async, buffered)
CPU usage: Low (CRC32 table)
I/O: Batch flushing
Memory: More efficient per key (~40B vs ~48B)
```

## Troubleshooting

### Common Issues

**1. Test compilation fails**
```bash
# Make sure you're in the project root
cd path/to/bitbarrel

# Check Nim version
nim --version  # Should be >= 2.0

# Try clearing nimcache
rm -rf nimcache
nim c -r tests/test_storage.nim
```

**2. Slow performance**
- Use `-d:release` flag
- Check if disks are busy (`iostat -x 1`)
- Verify you have enough RAM for KeyDir
- Consider reducing MAX_KEY_SIZE if needed

**3. "Too many open files" error**
```bash
# Increase file descriptor limit
ulimit -n 65536
```

**4. Tests fail intermittently**
- Could be timing-related (timestamp collision)
- Run tests individually to isolate issue
- Check disk space: `df -h`

### Debug Mode

Compile with debug symbols and runtime checks:

```bash
nim c -d:debug -r examples/basic_demo.nim
```

This enables:
- Range checks
- Overflow checks
- Stack traces on error
- Better debugging with gdb/lldb

## Best Practices

### 1. Use Appropriate Key Sizes

```nim
# Good: Short, descriptive keys
let key = "user:session:abc123"  # ~20 bytes

# Bad: Very long keys (waste memory)
let key = "my_application:production:database:user_table:user_id_12345:session_data"
```

### 2. Batch When Possible

```nim
# Instead of:
for item in items:
  dataFile.appendRecord(item.key, item.value, ts)
  # Each write is a separate I/O

# Consider:
const BATCH = 100
for i in 0..<items.len:
  buffer.add(recordData)
  if i mod BATCH == 0:
    flushBuffer()  # One I/O for 100 records
```

### 3. Monitor KeyDir Size

```nim
# Track memory usage periodically
if keyDir.len mod 10000 == 0:
  let memory = estimateMemoryUsage(keyDir)
  echo &"Keys: {keyDir.len}, Memory: {memory} MB"
```

### 4. Handle Timestamp Collisions

```nim
# Use monotonic timestamps
var lastTs = 0'i64

proc getTimestamp(): int64 =
  var ts = getTime().toUnix()
  if ts <= lastTs:
    ts = lastTs + 1
  lastTs = ts
  return ts
```

### 5. Verify Data Integrity

Always verify after writes:

```nim
let info = dataFile.appendRecord(key, value, ts)

# Verify immediately
let verifyInfo = RecordInfo(...)
let (k, v, _) = dataFile.readRecord(verifyInfo)
doAssert(k == key and v == value)
```

## Additional Resources

- [Bitcask Paper](https://riak.com/assets/bitcask-intro.pdf) - Original design
- [Nim by Example](https://nim-by-example.github.io/) - Nim language tutorial
- [PLAN.md](../PLAN.md) - Implementation roadmap
- [FEEDBACK.md](../FEEDBACK.md) - Code review feedback

## Next Steps

1. Run the basic demo to understand the API
2. Execute benchmarks to see current performance
3. Run stress tests to verify stability
4. Read the implementation code in `src/`
5. Consider implementing missing features from FEEDBACK.md

## Getting Help

If you encounter issues:

1. Check `TEST_RESULTS.md` for known test results
2. Review `FEEDBACK.md` for improvement areas
3. Run tests in debug mode for detailed errors
4. Check the implementation in `src/storage/`
5. Open an issue with detailed reproduction steps

---

**Happy coding!** 🚀

This BitBarrel implementation provides a solid foundation for high-performance storage. The combination of Bitcask's append-only design and Nim's efficiency makes it suitable for read-heavy workloads requiring low latency.
