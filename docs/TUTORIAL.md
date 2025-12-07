# KVS Tutorial: Building a High-Performance Key-Value Store

This tutorial walks you through using the Bitcask-based key-value store (KVS) implementation in Nim. By the end, you'll understand how to use the storage engine, run benchmarks, and stress-test the system.

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
cd path/to/kvstore
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
```

Expected output: All 13 tests should pass ✓

## Basic Concepts

### Bitcask Architecture

This KVS uses the Bitcask storage model:

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
- **Crash recovery**: Hint files for fast startup

### Core Components

1. **DataFile**: Handles reading/writing to disk
2. **KeyDir**: Thread-safe in-memory hash index
3. **Record**: Encodes/decodes key-value pairs

## Running Demos

### Basic Demo (samples/basic_demo.nim)

Demonstrates CRUD operations:

```bash
nim c -r samples/basic_demo.nim
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
║   KVS Demo: Basic CRUD Operations                         ║
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
2. **Large Values**: Values up to 1MB
3. **Rapid Writes**: 5K sequential writes as fast as possible
4. **Random Access**: Mixed reads/writes with 70/30 ratio
5. **Memory Usage**: 25K keys to measure overhead

**Expected Output:**
```
╔════════════════════════════════════════════════════════════╗
║ KVS Stress Test Suite                                     ║
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

### Bottlenecks and Limitations

**Current Bottlenecks:**
1. **No write buffering**: Every `appendRecord()` does I/O + flush
2. **Simple CRC32**: Bit-by-bit computation (slow)
3. **System call overhead**: Each operation requires syscalls

**Future Improvements:**
1. Write batching (10-100x speedup)
2. CRC32 lookup table (10-20x speedup)
3. Read-ahead buffering
4. Async I/O for network layer

## Advanced Usage

### Custom Configuration

```nim
import ../src/kvs/types
import ../src/storage
import ../src/storage/datafile

# Configure file size limits
const
  MAX_FILE_SIZE = 100 * 1024 * 1024  # 100MB per file
  MAX_KEY_SIZE = 1024                # 1KB max key
  MAX_VALUE_SIZE = 10 * 1024 * 1024  # 10MB max value

# Create data file with custom file ID
var dataFile = open("mydb_001.data", 1'u32)

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

While keys and values are stored as raw bytes, you can layer serialization on top:

```nim
import json

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
cd path/to/kvstore

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
nim c -d:debug -r samples/basic_demo.nim
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

This KVS implementation provides a solid foundation for high-performance storage. The combination of Bitcask's append-only design and Nim's efficiency makes it suitable for read-heavy workloads requiring low latency.
