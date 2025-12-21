# HugeBarrel Architecture Analysis

This document provides a detailed technical analysis of how HugeBarrel achieves massive scale - handling billions of keys and terabytes of data while maintaining constant memory usage.

## Overview

HugeBarrel is a **two-tier storage architecture** designed to scale from millions to billions of keys while maintaining constant memory usage (~100MB) regardless of dataset size.

### Core Design: Two Independent Barrels

```
HugeBarrel
├── Barrel1 (CritBit mode)
│   └── Stores serialized RangeKeyDir objects
│       Key: "R0000000001", "R0000000002", etc.
│       Value: Binary-serialized RangeKeyDir
│       Special: "__RANGES_METADATA__" (range boundaries)
│
└── Barrel2 (Multiple Data Files)
    ├── file_000001.data (actual KV data)
    ├── file_000002.data
    └── file_NNNNN.data
```

---

## How Billions of Keys Are Handled

### Range Partitioning Strategy

Keys are partitioned into **ranges** based on lexicographic ordering. Each range:
- Holds up to 100,000 entries (configurable)
- Has min/max key boundaries
- Is stored as a serialized blob in Barrel1

**In-memory structure** (constant size):
```nim
ranges: seq[tuple[minKey: string, maxKey: string, rangeKey: string]]
```

With 1 billion keys split into 10,000 ranges, this list is only ~1MB.

### Automatic Range Splitting

When a range exceeds 100,000 entries:
1. Find median key
2. Split into left and right RangeKeyDirs
3. Update Barrel1 with both new ranges
4. Delete old range
5. Update in-memory `hb.ranges` list

This ensures O(log R) range lookup regardless of total key count.

### LRU Cache for Bounded Memory

Only **10 RangeKeyDirs** are held in memory at once:

```nim
RangeKeyDirCache:
  cache: Table[string, RangeKeyDir]  # Max 10 entries
  lruList: seq[string]               # LRU ordering
```

Each RangeKeyDir is ~16KB serialized → **160KB total cache footprint**.

When accessing a range not in cache:
1. Evict least-recently-used entry
2. Load from Barrel1 (disk read)
3. Deserialize and add to cache

---

## Write Path (SET Operation)

```
1. Find Range
   ├─ Binary search on hb.ranges → O(log R)
   └─ If key fits no range, create new range

2. Write to Barrel2
   ├─ Append record: [CRC32][timestamp][keyLen][key][valLen][value]
   └─ Get back: RecordInfo (fileId, recordPos, valuePos, valueSize)

3. Update RangeKeyDir
   ├─ Load from cache (or Barrel1 if cache miss)
   ├─ Insert into pendingInserts table (O(1) hash insert)
   └─ Mark as dirty

4. Conditional Flush (every 1,000 pending inserts per range)
   ├─ Rebuild sorted array with pending entries
   ├─ Serialize to binary blob
   └─ Write to Barrel1 with rangeKey

5. File Rotation
   └─ If file > 1024MB, create new data file

6. Range Split (if > 100,000 entries)
   └─ Split at median key, update Barrel1 and hb.ranges
```

**Durability**: Data is immediately appended to Barrel2. RangeKeyDir metadata is batched (every 1,000 writes per range).

---

## Read Path (GET Operation)

```
1. Find Range
   └─ Binary search on hb.ranges → O(log R) ≈ 0.001ms

2. Load RangeKeyDir
   ├─ Check LRU cache first (O(1))
   ├─ If miss: Load from Barrel1 (~0.5ms disk I/O)
   └─ Deserialize blob (~0.1ms for 1,000 entries)

3. Search RangeKeyDir
   ├─ Check pendingInserts table (O(1))
   └─ If miss: Binary search sorted array → O(log N) ≈ 0.001ms

4. Read from Barrel2
   ├─ Open file identified by fileId
   ├─ Seek to recordPos
   ├─ Read and verify CRC32
   └─ Return value (~0.5ms disk I/O)
```

**Total latency**:
- Hot cache: ~0.5ms (single disk read)
- Cold cache: ~1.1ms (two disk reads)

---

## Handling Terabytes of Data

### Multi-File Data Storage

Barrel2 uses multiple data files with rotation:
- Each file capped at 1024MB (configurable via `maxDataFileSizeMB`)
- New file created when current exceeds limit
- Files named: `file_000001.data`, `file_000002.data`, etc.

**1TB of data** = ~1,000 files (each 1GB)

### Record Format (in Barrel2)

```
[CRC32: 4 bytes][timestamp: 8 bytes][keyLen: 4 bytes][key: N bytes][valLen: 4 bytes][value: M bytes]
```

### RangeKeyDir Entry Format

Each entry in the serialized RangeKeyDir:
```
- Key (2 byte length + string)
- fileId (4 bytes) - which Barrel2 file
- recordPos (8 bytes) - position in file
- valuePos (8 bytes) - where value starts
- valueSize (4 bytes)
- timestamp (8 bytes)
- recordSize (4 bytes)
- deleted flag (1 byte)
```

Total: ~37 bytes + key length per entry.

---

## Recovery on Restart

### Normal Startup

1. **Open Barrel1** (metadata barrel)
2. **Load `__RANGES_METADATA__`** key from Barrel1
3. **Parse range list** (format: `rangeKey\0minKey\0maxKey\0...`)
4. **Populate `hb.ranges`** in memory
5. **Open Barrel2** (data barrel)

No RangeKeyDirs are loaded into cache until accessed.

### Emergency Recovery (if metadata lost/corrupted)

If `__RANGES_METADATA__` is missing:

```
1. Scan all keys in Barrel1
2. For each key starting with "R":
   ├─ Load serialized RangeKeyDir
   ├─ Deserialize
   └─ Extract (rangeKey, minKey, maxKey)
3. Sort by minKey
4. Rebuild hb.ranges
5. Save recovered metadata to "__RANGES_METADATA__"
```

**Data safety**: No data is ever lost because:
- Barrel2 is append-only → data files are intact
- Barrel1 contains all RangeKeyDir blobs → can reconstruct range boundaries
- Emergency recovery can scan Barrel1 and rebuild the index

### Crash Safety

| Component | Safety Mechanism |
|-----------|-----------------|
| Barrel2 data | Append-only, CRC32 verified |
| RangeKeyDir metadata | Persisted to Barrel1 (also append-only) |
| Range boundaries | Saved to `__RANGES_METADATA__` on close and after splits |
| In-flight pendingInserts | Lost on crash (max 1,000 entries per range) |

**On crash**: Data in Barrel2 is safe. RangeKeyDir state in Barrel1 is safe. Only uncommitted pendingInserts (up to 1,000 per range) may be lost, but the corresponding data exists in Barrel2.

---

## Memory Usage Summary

| Component | Size | Notes |
|-----------|------|-------|
| RangeKeyDir cache | ~160KB | 10 x 16KB |
| Pending buffers | ~10KB | 10 x 1KB |
| hb.ranges list | R x 100B | R = number of ranges |
| Barrel1 KeyDir | ~100MB | One entry per range |
| **Total** | **~100MB** | Constant regardless of data size |

With 1 billion keys across 10,000 ranges: still ~100MB memory.

---

## Configuration Options

```nim
HugeBarrelConfig:
  maxEntriesPerRange: int      # When to split (default: 100,000)
  rangeCacheSize: int          # LRU cache size (default: 10)
  maxDataFileSizeMB: int       # File rotation size (default: 1024)
  autoSplitEnabled: bool       # Auto range split (default: true)
```

---

## Key Design Decisions

1. **Two-Barrel Separation**: Metadata (Barrel1) and data (Barrel2) are independent, allowing different optimization strategies for each.

2. **LRU Cache Strategy**: Keeping only 10 RangeKeyDirs in memory makes memory footprint independent of dataset size.

3. **Hybrid Indexing**: RangeKeyDir's sorted array + pending buffer pattern balances read performance (O(log n)) with write efficiency (avoid constant rebuilds).

4. **Lexicographic Range Distribution**: Uses key ordering for ranges, which enables range queries but can create hotspots with skewed key distributions.

5. **Emergency Recovery**: Scan-and-rebuild from Barrel1 ensures no data loss even if range metadata corrupts.

---

## File Structure on Disk

```
/path/to/hugebarrel/
├── barrel1/
│   ├── 000001.data      # Barrel1 data (CritBit mode)
│   │   ├── Record: "R0000000001" → [RangeKeyDir blob]
│   │   ├── Record: "R0000000002" → [RangeKeyDir blob]
│   │   ├── Record: "__RANGES_METADATA__" → [range list]
│   │   └── ...
│   └── 000002.data      # After Barrel1 compaction
│
└── barrel2/
    ├── file_000001.data # Data: [CRC32][ts][key][val]...
    ├── file_000002.data
    └── file_NNNNN.data  # New files as data grows
```
