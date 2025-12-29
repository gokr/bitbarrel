# BitBarrel Samples and Demos

This directory contains runnable examples demonstrating how to use the BitBarrel (Key-Value Store) library.

## Quick Start

### Run the Basic Demo

```bash
nim c -r examples/basic_demo.nim
```

This demonstrates CRUD operations (GET, SET, DELETE) and is the best starting point.

### Using Nimble

```bash
# Run basic demo
nimble demoBasic

# Run extended demo
nimble demoDemo
```

## Available Demos

### Core Demos

### 1. Basic Demo (`basic_demo.nim`)

**Features demonstrated:**
- Database initialization
- Storing key-value pairs (SET)
- Retrieving values (GET)
- Updating existing keys
- Deleting keys (tombstones)
- Final statistics

**Key concepts:**
- DataFile for storage
- KeyDir for in-memory indexing
- Record encoding/decoding
- CRC32 verification

### 2. Original Demo (`../examples/demo.nim`)

**Features demonstrated:**
- All basic operations
- File format details
- Header inspection
- File reopening/persistence
- Multiple records handling

### Reference Model Demos (NEW!)

These demos showcase the graph traversal capabilities added to BitBarrel.

### 3. Social Graph Demo (`social_graph_demo.nim`)

Demonstrates social network features with friends, posts, and interactions.

**Features:**
- User profiles with relationships
- Multi-level traversals (friends of friends)
- Array slicing for recent posts/comments
- Wildcard traversals

**Example queries:**
```nim
friends->team->matches        # Multi-step paths
friends[0:5]->posts[-1]       # Array slicing
*->comments                   # Wildcards
```

**Run it:**
```bash
nim c -r social_graph_demo.nim
```

### 4. Organization Chart Demo (`org_chart_demo.nim`)

Shows hierarchical data navigation for org charts and reporting structures.

**Features:**
- Upward and downward traversals
- Skip-level reporting analysis
- Management chain discovery
- Cross-department queries

**Example queries:**
```nim
direct_reports->direct_reports    # Downward traversal
manager->manager                    # Upward traversal
*->*                                # All relationships
```

**Run it:**
```bash
nim c -r org_chart_demo.nim
```

### 5. Content Graph Demo (`content_graph_demo.nim`)

Demonstrates content management with articles, tags, and recommendations.

**Features:**
- Related content discovery
- Tag-based navigation
- Content recommendations
- Comment thread analysis
- Graph metrics and analytics

**Example queries:**
```nim
tags->articles              # Tag-based navigation
related->related            # Related content chains
*->*                        # Full graph analysis
```

**Run it:**
```bash
nim c -r content_graph_demo.nim
```

**Documentation:** See `docs/REFERENCES.md` for complete reference model documentation.

## Code Examples

### Basic CRUD Pattern

```nim
import ../src/bitbarrel/types
import ../src/storage
from ../src/storage/datafile import open
from ../src/storage/keydir import init

# Initialize
var dataFile = open("database.data", 1'u32)
var keyDir = init()

# SET
let info = dataFile.appendRecord("key", "value", timestamp)
keyDir.add("key", KeyDirEntry(
  fileId: 1,
  recordPos: info.recordPos,
  valuePos: info.valuePos,
  valueSize: info.valueSize,
  timestamp: timestamp,
  recordSize: info.recordSize
))

# GET
let found = keyDir.get("key")
if found.isSome():
  let entry = found.get()
  let (key, value, ts) = dataFile.readRecord(entry.recordPos)
  echo value

# Update (write new record, old becomes garbage)
let newInfo = dataFile.appendRecord("key", "new_value", timestamp)
keyDir.add("key", KeyDirEntry(...))  # Overwrites index

# DELETE (write empty value = tombstone)
let delInfo = dataFile.appendRecord("key", "", timestamp)
keyDir.add("key", KeyDirEntry(...))

# Cleanup
dataFile.close()
```

### Batch Operations

```nim
proc batchInsert(dataFile: var DataFile, keyDir: var KeyDir, items: seq[(string, string)]) =
  for (key, value) in items:
    let ts = getTime().toUnix()
    let info = dataFile.appendRecord(key, value, ts)
    keyDir.add(key, KeyDirEntry(
      fileId: 1,
      recordPos: info.recordPos,
      valuePos: info.valuePos,
      valueSize: info.valueSize,
      timestamp: ts,
      recordSize: info.recordSize
    ))

# Usage
let data = @[("key1", "value1"), ("key2", "value2"), ("key3", "value3")]
batchInsert(dataFile, keyDir, data)
```

### Error Handling

```nim
try:
  let info = dataFile.appendRecord(key, value, timestamp)
  if info.recordSize == 0:
    raise newException(ValueError, "Empty record")
  keyDir.add(key, keyDirEntry)
except IOError:
  echo "Failed to write to disk"
except ValueError:
  echo "Invalid record data"
```

## Performance Characteristics

Based on running the demos:

- **Write latency**: ~0.01ms per record (10,000 writes = 0.1s)
- **Read latency**: ~0.009ms per record (10,000 reads = 0.09s)
- **Record overhead**: ~20 bytes per key-value pair
- **KeyDir overhead**: ~48 bytes per key (in memory)

### Example: Writing 1000 Records

```nim
let start = getTime().toUnixFloat()
for i in 0..<1000:
  let key = &"key_{i}"
  let value = &"value_{i}"
  discard dataFile.appendRecord(key, value, ts)
let elapsed = getTime().toUnixFloat() - start
# Expected: ~0.01 seconds = 100K ops/sec
```

## File Format

Data files have this structure:

```
┌─────────────────────────────────────────┐
│ Header (32 bytes)                       │
│  - Magic: "BCKS" (4 bytes)             │
│  - Version: uint32                      │
│  - Created: int64 (timestamp)           │
│  - File Size: uint64                    │
│  - Reserved: 8 bytes                    │
├─────────────────────────────────────────┤
│ Record 1                                │
│  - CRC32: 4 bytes                       │
│  - Timestamp: 8 bytes                   │
│  - Key Length: 4 bytes                  │
│  - Key: variable                        │
│  - Value Length: 4 bytes                │
│  - Value: variable                      │
├─────────────────────────────────────────┤
│ Record 2                                │
│  ...                                     │
└─────────────────────────────────────────┘
```

## Best Practices

### 1. Always Use KeyDir

The KeyDir is your in-memory index. Always update it when writing:

```nim
# Write record
let info = dataFile.appendRecord(key, value, ts)

# MUST update KeyDir
keyDir.add(key, KeyDirEntry(...))
```

### 2. Handle RecordInfo Properly

`RecordInfo` from `appendRecord` contains critical position data:

```nim
let info = dataFile.appendRecord(key, value, ts)
# Use these fields in KeyDirEntry:
# - info.recordPos (where CRC32 is)
# - info.valuePos (where value starts)
# - info.valueSize (value length)
# - info.recordSize (total record size)
```

### 3. Clean Up Resources

Always close files:

```nim
defer:
  dataFile.close()
  if fileExists(dbPath):
    removeFile(dbPath)
```

### 4. Use Meaningful Keys

Good key patterns:
```nim
"user:{user_id}"
"session:{session_id}"
"config:{setting_name}"
```

Bad key patterns:
```nim
"data"  # Not unique
"very:long:nested:key:that:exceeds:reasonable:length"  # Too long
```

### 5. Version Your Data

Include version in keys for migrations:

```nim
let key = "user:v1:{user_id}"
# Later can migrate to v2
```

## Troubleshooting

**"Cannot open file" error**
- Check file permissions
- Ensure directory exists: `createDir("data")`

**"Invalid record" error**
- Key or value may exceed MAX_SIZE limits
- Timestamp might be invalid (<= 0)

**Slow performance**
- Use `-d:release` flag
- Check disk space: `df -h`
- Monitor I/O: `iostat -x 1`

**Memory usage growing**
- KeyDir stores all keys in memory
- Each key uses ~48 bytes overhead
- For 1M keys: ~48MB RAM needed

## Extending the Demos

Use these demos as templates for your own applications:

1. **Configuration Storage**: Store app settings
2. **Session Management**: Track user sessions
3. **Cache**: Simple key-value cache
4. **Event Store**: Append-only event log
5. **Metric Storage**: Time-series data

## Next Steps

- Read `docs/TUTORIAL.md` for advanced topics
- Run benchmarks: `nimble bench`
- Run stress tests: `nimble stress`
- Check `../TEST_RESULTS.md` for performance data
- Review implementation in `../src/`

## Demo Output Example

When you run `nim c -r examples/basic_demo.nim`, you should see:

```
╔════════════════════════════════════════════╗
║   BitBarrel Demo: Basic CRUD Operations         ║
╚════════════════════════════════════════════╝

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

---

**Useful Commands**

```bash
# Run all tests
nimble test

# Run specific test
nim c -r tests/test_storage.nim

# Benchmark
nimble bench

# Stress test
nimble stress

# Clean up
nimble clean
```
