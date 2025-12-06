# NimKVS - High-Performance Bitcask Key/Value Store

A simple but extremely performant key/value store implemented in Nim using the Bitcask storage model.

## Features

- **Append-only storage** for optimal write performance
- **In-memory hash index** for O(1) read operations
- **Crash-safe** with proper fsync semantics
- **Fast recovery** with hint files
- **Automatic compaction** to reclaim space
- **Binary protocol** for efficient network communication

## Performance Targets

| Operation | Latency (p50/p99) | Throughput |
|-----------|-------------------|------------|
| GET       | 5μs / 20μs        | 100,000+ ops/sec |
| SET       | 15μs / 50μs       | 50,000+ ops/sec |
| DELETE    | 10μs / 30μs       | 100,000+ ops/sec |

## Quick Start

```nim
import kvs

# Open a database
let db = openKVS("./data")

# Set a value
db.set("key", "value")

# Get a value
let value = db.get("key")  # Option[string]

# Delete a value
db.delete("key")

# Close the database
db.close()
```

## Building

```bash
nimble build
```

## Testing

```bash
nimble test
```

## Architecture

This implementation uses the Bitcask storage model:

1. **Data Files**: Append-only log files with all writes
2. **Key Directory**: In-memory hash index mapping keys to data locations
3. **Hint Files**: Periodic snapshots for fast recovery
4. **Merge Process**: Background compaction to reclaim space

See [PLAN.md](PLAN.md) for detailed architecture and implementation roadmap.

## License

MIT License