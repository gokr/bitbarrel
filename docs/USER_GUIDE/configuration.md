# BitBarrel Configuration Guide

## Overview

BitBarrel provides a flexible configuration system that supports multiple configuration methods:
- YAML configuration files
- Environment variables (with `BITBARREL_` prefix)
- Programmatic configuration via types
- Default values for all options

## Configuration Types

### 1. BarrelConfig (High-Level API)

For basic applications using the high-level Barrel API.

```nim
type
  BarrelConfig* = object
    # Storage configuration
    writeBufferSize*: int            # Write buffer size in bytes
    syncMode*: UserSyncMode          # Durability level
    autoCompact*: bool              # Enable automatic compaction
    compactThreshold*: float         # Fragmentation threshold (0.0-1.0)
    validateCrc*: bool              # Validate CRC32 on reads

    # TTL configuration
    defaultTtl*: int                 # Default TTL in seconds (0 = no expiration)
    checkExpirationOnRead*: bool     # Check expiration during get() calls
    deleteExpiredOnRead*: bool       # Write tombstone for expired records

    # Index mode
    mode*: BarrelMode               # Index type (see Index Modes section)

    # HugeBarrel configuration (only when mode = bmHugeCritBit)
    hugeConfig*: HugeBarrelConfig
```

#### UserSyncMode Options

| Mode | Description | Durability | Performance |
|------|-------------|------------|-------------|
| `None` | No sync to disk | Lowest data safety | Highest performance |
| `Sync` | Sync to OS buffer | Good (OS-managed) | Balanced |
| `Fsync` | Force sync to disk | Highest data safety | Lowest performance |

#### Default Values for BarrelConfig

```nim
writeBufferSize: 64 * 1024      # 64KB
syncMode: UserSyncMode.Sync     # Balanced durability
autoCompact: true               # Enable compaction
compactThreshold: 0.3           # 30% fragmentation
validateCrc: true               # CRC validation enabled
defaultTtl: 0                   # No expiration
checkExpirationOnRead: true     # Check TTL on reads
deleteExpiredOnRead: false      # Don't auto-delete expired
mode: bmHash                    # Hash table mode
```

### 2. HugeBarrelConfig (For Massive Datasets)

Used only with `bmHugeCritBit` mode for datasets larger than memory.

```nim
type
  HugeBarrelConfig* = object
    maxEntriesPerRange*: int      # Max entries per RangeKeyDir (default: 100_000)
    rangeCacheSize*: int          # Max RangeKeyDirs in memory (default: 10)
    maxDataFileSizeMB*: int       # Max file size per range (default: 1024 MB)
    autoSplitEnabled*: bool       # Automatic range splitting (default: true)
```

## Index Modes

BitBarrel supports three index modes:

### bmHash (Default)
- Hash table in-memory index
- O(1) lookup time
- No ordering support
- Best for simple key-value lookups

### bmCritBit
- CritBit tree structure
- O(key_length) lookup time
- Supports prefix and range queries
- Efficient for ordered data

### bmHugeCritBit
- Two-tier architecture for massive datasets
- Supports range queries
- Automatic range splitting
- Suitable for datasets larger than available memory

## Configuration Example Files

### Basic YAML Configuration (bitbarrel.yaml)

```yaml
# BitBarrel Configuration
# Save as bitbarrel.yaml in your project directory

storage:
  data_dir: "./data"
  max_file_size: 1073741824  # 1GB
  max_key_size: 65536        # 64KB
  max_value_size: 1048576    # 1MB
  sync_mode: "immediate"     # immediate, buffered, batched, time_based
  validate_crc: true

performance:
  worker_threads: 4
  write_buffer_size: 65536   # 64KB
  cache_size: 256            # MB

compact:
  enabled: true
  trigger_threshold: 0.3      # 30% fragmentation
  compact_interval: 60        # seconds

logging:
  level: "info"               # debug, info, warn, error
  file: "bitbarrel.log"
```

### Programmatic Configuration Examples

#### High-Performance Setup

```nim
import bitbarrel

var config = defaultBarrelConfig()
config.writeBufferSize = 1024 * 1024  # 1MB buffer
config.syncMode = UserSyncMode.None   # No sync for speed
config.autoCompact = true
config.compactThreshold = 0.4         # Compact at 40% fragmentation

let db = openBarrel("/path/to/data", config)
```

#### Maximum Durability Setup

```nim
var config = defaultBarrelConfig()
config.writeBufferSize = 32 * 1024    # Small buffer for frequent syncs
config.syncMode = UserSyncMode.Fsync  # Fsync on every write
config.validateCrc = true             # CRC validation
config.autoCompact = true

let db = openBarrel("/path/to/data", config)
```

#### Huge Dataset with Range Queries

```nim
var config = defaultBarrelConfig()
config.mode = bmHugeCritBit
config.hugeConfig.maxEntriesPerRange = 200_000
config.hugeConfig.rangeCacheSize = 20
config.hugeConfig.maxDataFileSizeMB = 2048
config.hugeConfig.autoSplitEnabled = true

let db = openBarrel("/path/to/data", config)
```

## Environment Variables

All configuration options can be overridden via environment variables with the pattern:

```
BITBARREL_SECTION_SETTING=value
```

Examples:
- `BITBARREL_STORAGE_DATA_DIR=/var/lib/bitbarrel`
- `BITBARREL_STORAGE_SYNC_MODE=buffered`
- `BITBARREL_PERFORMANCE_WORKER_THREADS=8`
- `BITBARREL_COMPACT_ENABLED=false`
- `BITBARREL_LOGGING_LEVEL=debug`

## Performance Tuning Guidelines

### Write-Heavy Workloads
- Use `UserSyncMode.None` or `syncBuffered`
- Increase `writeBufferSize` to 1MB or more
- Consider larger batch sizes for writes

### Read-Heavy Workloads
- Increase read buffer cache if available
- `syncImmediate` is acceptable for writes
- Consider CritBit mode for ordered access patterns

### Balanced Workloads
- Use `UserSyncMode.Sync` (default)
- 256KB write buffer
- Default compaction settings

### Memory-Constrained Environments
- Use `bmHash` mode (lowest memory usage)
- Reduce `writeBufferSize`
- Smaller cache size
- Consider `syncBuffered` to reduce I/O

## Constants and Limits

```nim
MAX_KEY_SIZE* = 64 * 1024      # 64KB
MAX_VALUE_SIZE* = 1 * 1024 * 1024  # 1MB (can be configured higher)
HEADER_SIZE* = 32              # File header size
MAGIC_NUMBER* = "BCKS"         # File format identifier
```

## Using Configuration From Files

```nim
import bitbarrel

# Load from YAML file
let config = loadConfigFromFile("bitbarrel.yaml")
let db = openBarrel("/data", config)

# Or use environment variables + defaults
let config = loadConfigFromEnv()
let db = openBarrel("/data", config)
```

## Next Steps

- [API Reference](api-reference.md) - Full API documentation
- [Tutorial](tutorial.md) - Comprehensive usage guide
- [Performance Guide](../DEVELOPER_GUIDE/performance.md) - Benchmarking and optimization