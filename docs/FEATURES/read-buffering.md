# Read-Ahead LRU Buffering in BitBarrel

The read-ahead LRU (Least Recently Used) buffering system caches frequently accessed data using LRU eviction policy with read-ahead prediction. It reduces disk I/O and improves read throughput for mixed workloads.

## Overview

- **Performance boost**: Improves read throughput to ~172K ops/sec (random access)
- **LRU eviction**: Automatically evicts least recently used entries when cache limits reached
- **Multiple implementations**: Main read buffer, range cache, HugeBarrel cache
- **Configurable**: Memory limits, cache size tuning based on workload
- **Thread-safe**: Concurrent access with proper locking

## Core Implementation

### Main Read Buffer (`src/storage/readbuffer.nim`)
The primary LRU cache for record data:

```nim
type
  ReadBuffer* = object
    cache*: Table[CacheKey, CacheEntry]
    maxSize*: int           # Maximum number of entries
    maxMemory*: int64       # Maximum memory in bytes
    currentSize*: int       # Current number of entries
    currentMemory*: int64   # Current memory usage
    stats*: ReadBufferStats
    lock*: Lock
    enabled*: bool

  CacheEntry* = object
    data*: string           # Cached record data
    accessTime*: Time       # Last access time for LRU eviction
    accessCount*: int       # Access count for statistics

  CacheKey* = tuple[fileId: uint32, offset: uint64]  # Unique record identifier
```

### How LRU Eviction Works
1. **Track access time**: Each cache entry stores `accessTime` (last access timestamp)
2. **Eviction scan**: When cache limits exceeded, scan all entries to find oldest `accessTime`
3. **Remove oldest**: Evict the entry with the oldest access time
4. **Update statistics**: Track hits, misses, evictions for monitoring

**Eviction procedure** (`evictOldest` in `readbuffer.nim`):
```nim
proc evictOldest*(buffer: var ReadBuffer): bool =
  ## Evicts the least recently used entry from the cache
  var oldestTime = Time(int64.high)
  var oldestKey: CacheKey
  var found = false

  for key, entry in buffer.cache.pairs():
    if entry.accessTime < oldestTime:
      oldestTime = entry.accessTime
      oldestKey = key
      found = true

  if found:
    buffer.stats.evictions += 1
    buffer.currentMemory -= buffer.cache[oldestKey].data.len.int64
    buffer.cache.del(oldestKey)
    buffer.currentSize -= 1

  return found
```

## Additional LRU Implementations

### Range Cache (`src/storage/rangecache.nim`)
For `bmHugeCritBit` mode with partitioned datasets:
- LRU cache for loaded range partitions
- Manages which range indexes stay in memory
- Evicts oldest ranges when cache is full
- Key: `rangeId` string, Value: `RangeKeyDir` object

### HugeBarrel RangeKeyDir Cache (`src/storage/hugebarrel.nim`)
Two-tier storage for massive datasets:
- LRU cache for `RangeKeyDir` objects
- Maintains `lruList: seq[string]` for tracking access order
- Automatic eviction with dirty flag tracking
- Configurable `rangeCacheSize` (default: 10 ranges)

## Performance Characteristics

### Benchmark Results (recent benchmarks, ThinkPad Carbon X1 with SSD)
- **Read throughput**: ~172K ops/sec (random access via in-memory index)
- **Mixed workload** (80% read / 20% write): ~137K ops/sec (combined operations)
- **Write latency** (with buffering): ~0.005 ms (sub-millisecond)
- **Read latency**: ~0.006 ms (O(1) hash lookup + cache check)

### Cache Hit Rates
Typical hit rates depend on workload:
- **Temporal locality**: 60-80% for recently accessed data
- **Spatial locality**: 40-60% for sequential scans
- **Random access**: 20-40% for truly random workloads
- **Mixed workloads**: 50-70% for typical database usage

### Memory Usage
- **Per entry overhead**: ~50 bytes metadata + cached data size
- **Typical cache size**: 256 MB - 2 GB (configurable)
- **Eviction threshold**: 90% of max memory triggers LRU cleanup

## Configuration

### Runtime Configuration
Read buffering can be controlled via configuration:

```yaml
storage:
  data_dir: "./data"
  read_buffer:
    enabled: true                    # Enable read buffering (default: true)
    max_size: 10000                  # Maximum number of cache entries (default: 10000)
    max_memory: 268435456            # Maximum memory in bytes (default: 256MB)
    eviction_policy: "lru"           # Eviction policy: "lru", "fifo", "none"
    stats_enabled: true              # Enable cache statistics (default: true)

  huge_barrel:
    range_cache_size: 10             # Number of ranges to keep in memory (default: 10)
    range_cache_enabled: true        # Enable range caching (default: true)
```

### Environment Variables
```
BITBARREL_READ_BUFFER_ENABLED=true
BITBARREL_READ_BUFFER_MAX_SIZE=10000
BITBARREL_READ_BUFFER_MAX_MEMORY=268435456
BITBARREL_HUGE_RANGE_CACHE_SIZE=10
```

### Compile-time Options
```
# Build with aggressive caching (larger defaults)
nim c -d:aggressiveCaching -d:release src/bitbarrel.nim

# Build with minimal caching (memory-constrained environments)
nim c -d:minimalCaching -d:release src/bitbarrel.nim
```

## Best Practices

### Sizing Guidelines
1. **General purpose**: 256 MB cache for databases < 10 GB
2. **Large datasets**: 1-2 GB cache for databases 10-100 GB
3. **Memory-constrained**: 64-128 MB minimum for noticeable benefit
4. **Range caches**: 10-50 ranges for `bmHugeCritBit` mode

### Workload Optimization
1. **Sequential scans**: Larger cache sizes (1 GB+) for read-ahead
2. **Random access**: Moderate cache sizes (256 MB-1 GB)
3. **Mixed workloads**: Balance between read and write buffer sizes
4. **Time-series data**: Consider temporal caching patterns

### Monitoring
Monitor cache statistics:
- **Hit rate**: `hits / (hits + misses)` - aim for > 60%
- **Eviction rate**: High evictions may indicate undersized cache
- **Memory usage**: Keep below 90% of max to avoid thrashing
- **Entry count**: Monitor growth patterns

## Troubleshooting

### Low Cache Hit Rate
- Increase cache size (`max_memory`, `max_size`)
- Check workload patterns (truly random access has lower hit rates)
- Verify cache is enabled (`enabled: true`)
- Monitor for memory pressure causing premature evictions

### High Eviction Rate
- Cache may be too small for working set
- Consider increasing `max_memory`
- Check for memory leaks in application
- Monitor system memory usage

### Performance Regression
- Verify cache is actually being used (check stats)
- Ensure proper locking isn't causing contention
- Check for cache key collisions (unlikely but possible)
- Monitor CPU usage during cache operations

### Memory Exhaustion
- Reduce `max_memory` to fit within available RAM
- Consider `eviction_policy: "lru"` (more aggressive)
- Monitor system swap usage
- Adjust other memory-intensive components (write buffers, etc.)

## API Reference

### Read Buffer API (`src/storage/readbuffer.nim`)
```nim
# Create a read buffer
var buffer = newReadBuffer(maxSize = 10000, maxMemory = 256 * 1024 * 1024)

# Store data in cache
buffer.put(fileId = 1'u32, offset = 1024'u64, data = "cached value")

# Retrieve from cache
let cached = buffer.get(fileId = 1'u32, offset = 1024'u64)
if cached.isSome:
  echo "Cache hit: ", cached.get()

# Get statistics
let stats = buffer.getStats()
echo "Hits: ", stats.hits, " Misses: ", stats.misses, " Hit rate: ", stats.hitRate

# Clear cache
buffer.clear()
```

### Range Cache API (`src/storage/rangecache.nim`)
```nim
# Cache a range
rangeCache.put("range:0-1000000", rangeKeyDir)

# Get a range
let range = rangeCache.get("range:0-1000000")

# Get cache statistics
let stats = rangeCache.stats()
```

## Testing

Run cache-related tests:

```bash
# Test read buffer implementation
nim c -r --path:src tests/test_readbuffer.nim

# Test range cache
nim c -r --path:src tests/test_rangecache.nim

# Test HugeBarrel caching
nim c -r --path:src tests/test_hugebarrel.nim

# Performance benchmark
nim c -r --path:src bench/read_cache_bench.nim

# Run all storage tests
nimble testStorage
```

## Migration and Compatibility

- **Version compatibility**: Cache formats are internal; no compatibility concerns
- **Disabling cache**: Safe to disable - reads will go directly to disk (slower)
- **Changing size**: Can be adjusted without restart (dynamic reconfiguration)
- **Cache invalidation**: Automatic on record updates/deletes
- **Cluster deployments**: Each node maintains its own cache (no shared cache)

## Related Features

### Write Buffering
Complementary to read buffering:
- Write buffer: Batches writes for sequential I/O
- Read buffer: Caches reads for reduced disk I/O
- Both use similar configuration patterns

### Read-Ahead Prediction
Future enhancement:
- Predict next reads based on access patterns
- Pre-fetch data before it's requested
- Currently: Simple LRU of accessed data

### Compression Integration
Cached data remains compressed:
- Memory savings: Store compressed data in cache
- Decompress on cache hit
- Trade-off: CPU vs. memory