# BitBarrel API Reference

## Overview

BitBarrel provides a high-performance Bitcask-style key-value storage engine with multiple API layers:
- **High-Level Barrel API** - Simple key-value operations with multiple index modes
- **HugeBarrel API** - Two-tier storage for massive datasets with range queries
- **Network Client API** - WebSocket-based remote access
- **Low-Level API** - Direct storage primitives

---

## High-Level Barrel API (`src/bitbarrel/barrel.nim`)

### Core Type

```nim
type Barrel* = ref BarrelObj
```
Main storage container supporting multiple index modes (Hash, CritBit, HugeCritBit).

### Configuration

```nim
proc defaultBarrelConfig*(): BarrelConfig
```
Returns default configuration for Barrel with:
- 64KB write buffer
- Immediate sync mode
- Auto-compaction enabled
- 30% compaction threshold
- CRC validation enabled
- Hash mode by default

```nim
type BarrelConfig* = object
  writeBufferSize*: int           # Buffer size for writes
  syncMode*: UserSyncMode        # None, Sync, or Fsync
  autoCompact*: bool             # Enable background compaction
  compactThreshold*: float       # Fragmentation threshold (0.0-1.0)
  validateCrc*: bool            # Validate CRC32 on reads
  defaultTtl*: int              # Default TTL in seconds (0 = no expire)
  checkExpirationOnRead*: bool  # Check TTL during get()
  deleteExpiredOnRead*: bool    # Auto-write tombstones for expired keys
  mode*: BarrelMode             # Hash, CritBit, or HugeCritBit
  hugeConfig*: HugeBarrelConfig # Config for HugeCritBit mode
```

```nim
type BarrelMode* = enum
  bmHash         # Hash table - O(1) lookup
  bmCritBit      # CritBit tree - ordered, supports range queries
  bmHugeCritBit  # Two-tier for massive datasets
```

```nim
type UserSyncMode* = enum
  None = "none"    # No sync (fastest)
  Sync = "sync"    # Sync to OS buffer
  Fsync = "fsync"  # Sync to disk (safest)
```

### Barrel Lifecycle

```nim
proc openBarrel*(path: string, fileId: uint32 = 1'u32, config: BarrelConfig = defaultBarrelConfig()): Barrel
```
Open a barrel with optional configuration and file ID.

**Parameters:**
- `path`: Path to data file
- `fileId`: File identifier (default: 1)
- `config`: Configuration options (default: default config)

**Returns:** Initialized Barrel instance

```nim
proc openBarrel*(path: string, config: BarrelConfig): Barrel
```
Open a barrel with configuration (no fileId needed).

```nim
proc close*(barrel: Barrel)
```
Close the barrel and release resources.

```nim
proc isClosed*(barrel: Barrel): bool
```
Check if the barrel is closed.

### Basic Operations

```nim
proc set*(barrel: Barrel, key: string, value: string, ttl: int = -1): bool
```
Set a key-value pair with optional TTL.

**Parameters:**
- `key`: Key string (max 64KB)
- `value`: Value string (max 1MB)
- `ttl`: TTL in seconds, -1 uses default, 0 = no expiration

**Returns:** true if successful

```nim
proc get*(barrel: Barrel, key: string): string
```
Get a value by key.

**Parameters:**
- `key`: Key to retrieve

**Returns:** Value string or empty string if not found

```nim
proc delete*(barrel: Barrel, key: string): bool
```
Delete a key using tombstone record.

**Parameters:**
- `key`: Key to delete

**Returns:** true if successful

```nim
proc exists*(barrel: Barrel, key: string): bool
```
Check if a key exists (O(1) operation).

**Parameters:**
- `key`: Key to check

**Returns:** true if key exists and not deleted

### Query Operations

```nim
proc count*(barrel: Barrel): int
```
Get number of non-deleted keys in store.

```nim
proc listKeys*(barrel: Barrel, limit: int = 1000, offset: int = 0): seq[string]
```
List non-deleted keys with pagination.

**Parameters:**
- `limit`: Maximum keys to return (default: 1000)
- `offset`: Number of keys to skip (default: 0)

**Returns:** Sequence of keys

```nim
proc clear*(barrel: Barrel): bool
```
Clear all keys (values remain in file but inaccessible).

**Returns:** true if successful

### TTL Operations

```nim
proc setTtl*(barrel: Barrel, key: string, ttlSeconds: int): bool
```
Set TTL for an existing key (rewrites the record).

**Parameters:**
- `key`: Existing key
- `ttlSeconds`: New TTL in seconds

**Returns:** true if key existed and TTL was set

```nim
proc getTtl*(barrel: Barrel, key: string): int
```
Get remaining TTL for a key in seconds.

**Parameters:**
- `key`: Key to check

**Returns:** Remaining TTL seconds, 0 if no expiration or not found

### Range Query Operations (CritBit Mode Only)

```nim
proc keysWithPrefix*(barrel: Barrel, prefix: string, limit: int = 1000, offset: int = 0): seq[string]
```
Get keys that start with given prefix (efficient in CritBit mode).

**Parameters:**
- `prefix`: Prefix to match
- `limit`: Maximum keys to return
- `offset`: Number of keys to skip

**Returns:** Matching keys

```nim
proc keysInRange*(barrel: Barrel, startKey: string, endKey: string, limit: int = 1000, offset: int = 0): seq[string]
```
Get keys in range [startKey, endKey).

**Parameters:**
- `startKey`: Inclusive start key
- `endKey`: Exclusive end key
- `limit`: Maximum keys to return
- `offset`: Number of keys to skip

**Returns:** Keys in range

```nim
proc countWithPrefix*(barrel: Barrel, prefix: string): int
```
Count non-deleted keys with given prefix.

**Parameters:**
- `prefix`: Prefix to match

**Returns:** Count of matching keys

### Utility Functions

```nim
proc getMode*(barrel: Barrel): BarrelMode
```
Get the index mode of the barrel.

```nim
proc getConfig*(barrel: Barrel): BarrelConfig
```
Get the configuration of the barrel.

```nim
proc getPath*(barrel: Barrel): string
```
Get the data file path.

```nim
proc indexCount*(barrel: Barrel): int
```
Get number of entries in index (including tombstones).

---

## HugeBarrel API (`src/storage/hugebarrel.nim`)

For massive datasets requiring two-tier storage with range queries.

### Configuration

```nim
type HugeBarrelConfig* = object
  maxEntriesPerRange*: int      # Max entries per range (default: 100_000)
  rangeCacheSize*: int          # Max RangeKeyDirs in memory (default: 10)
  maxDataFileSizeMB*: int       # Max data file size in MB (default: 1024)
  autoSplitEnabled*: bool       # Enable auto-range splitting (default: true)
```

### Core Type

```nim
type HugeBarrel* = ref object
  path*: string
  config*: HugeBarrelConfig
  barrel1*: Barrel              # Stores RangeKeyDirs
  barrel2Files*: Table[uint32, ref DataFile]  # Data files
  ranges*: seq[tuple[minKey: string, maxKey: string, rangeKey: string]]
  rangeKeyCache*: RangeKeyDirCache
```

### Lifecycle

```nim
proc openHugeBarrel*(path: string, config: BarrelConfig): HugeBarrel
```
Open a HugeBarrel (config mode must be bmHugeCritBit).

**Parameters:**
- `path`: Storage directory path
- `config`: BarrelConfig with bmHugeCritBit mode

**Returns:** Initialized HugeBarrel

```nim
proc close*(hb: var HugeBarrel)
```
Close the HugeBarrel and save all cached data.

### Basic Operations

```nim
proc get*(hb: var HugeBarrel, key: string): string
proc get*(hb: HugeBarrel, key: string): string
```
Get value for a key.

```nim
proc set*(hb: var HugeBarrel, key: string, value: string, ttl: int = -1): bool
```
Set a key-value pair.

```nim
proc delete*(hb: var HugeBarrel, key: string): bool
```
Delete a key using tombstone.

```nim
proc exists*(hb: HugeBarrel, key: string): bool
```
Check if key exists.

### Range Management

```nim
proc findRangeForKey*(hb: HugeBarrel, key: string): string
```
Find which range a key belongs to (binary search).

**Returns:** Range key or empty string if not found

```nim
proc splitRange*(hb: var HugeBarrel, rangeKey: string): (string, string)
```
Split a range into two halves at median key.

**Returns:** (leftRangeKey, rightRangeKey)

```nim
proc shouldSplitRange*(hb: HugeBarrel, rangeKey: string): bool
```
Check if a range needs splitting.

### Range Metadata

```nim
proc getRangeCount*(hb: HugeBarrel): int
```
Get number of ranges.

```nim
proc getRangeKeys*(hb: HugeBarrel): seq[string]
```
Get all range keys.

```nim
proc flushAllRanges*(hb: var HugeBarrel): int
```
Flush all dirty ranges to Barrel1.

**Returns:** Number of ranges flushed

---

## Network Client API (`src/network/client.nim`)

WebSocket-based client for remote BitBarrel access.

### Configuration

```nim
type ClientConfig* = object
  host*: string              # Default: "localhost"
  port*: Port              # Default: 9876
  connectTimeout*: int     # ms, default: 5000
```

### Client Creation

```nim
proc newClient*(config: ClientConfig): BitBarrelClient
```
Create a new BitBarrel client with configuration.

```nim
proc newClient*(host: string = "localhost", port: Port = 9876.Port): BitBarrelClient
```
Create client with default configuration.

### Connection Management

```nim
type BitBarrelClient* = object
  host*: string
  port*: Port
  conn*: WebSocket
  seqCounter*: uint32
  currentBarrel*: string
```

```nim
proc connect*(client: var BitBarrelClient)
```
Connect to the server.

```nim
proc close*(client: var BitBarrelClient)
```
Close connection.

### Barrel Management

```nim
proc createBarrel*(client: var BitBarrelClient, name: string, config: string = ""): bool
```
Create a new barrel on server.

```nim
proc openBarrel*(client: var BitBarrelClient, name: string): bool
```
Open an existing barrel.

```nim
proc useBarrel*(client: var BitBarrelClient, name: string): bool
```
Set current barrel for this session.

```nim
proc listBarrels*(client: var BitBarrelClient): seq[string]
```
List all available barrels.

### Basic Operations

```nim
proc get*(client: var BitBarrelClient, key: string): string
```
Get value by key.

```nim
proc set*(client: var BitBarrelClient, key, value: string): bool
```
Set key-value pair.

```nim
proc delete*(client: var BitBarrelClient, key: string): bool
```
Delete a key.

```nim
proc exists*(client: var BitBarrelClient, key: string): bool
```
Check if key exists.

```nim
proc ping*(client: var BitBarrelClient): bool
```
Ping the server.

---

## Type Definitions (`src/bitbarrel/types.nim`)

### Core Types

```nim
type KeyDirEntry* = object
  fileId*: uint32      # Data file containing record
  recordPos*: uint64   # Record position in file
  valuePos*: uint64    # Value position
  valueSize*: uint32   # Value size
  timestamp*: int64    # For TTL/conflict resolution
  recordSize*: uint32  # Total record size
  deleted*: bool       # True if tombstone
```

```nim
type FileHeader* = object
  magic*: array[4, char]  # "BCKS"
  version*: uint32
  created*: int64
  fileSize*: uint64
  reserved*: array[8, byte]
```

### Constants

```nim
const MAGIC_NUMBER* = "BCKS"
const VERSION* = 1'u32
const HEADER_SIZE* = 32
const MAX_KEY_SIZE* = 64 * 1024  # 64KB
const MAX_VALUE_SIZE* = 1 * 1024 * 1024  # 1MB
```

---

## Usage Examples

### Basic Usage
```nim
import bitbarrel

# Open database
let barrel = openBarrel("mydata.db")

# Set values
discard barrel.set("user:1", "Alice")
discard barrel.set("user:2", "Bob", ttl: 3600)  # 1 hour TTL

# Get values
echo barrel.get("user:1")  # "Alice"
echo barrel.get("user:3")  # "" (not found)

# Check existence
if barrel.exists("user:2"):
  echo "User 2 exists"

# List keys
for key in barrel.listKeys():
  echo key

# Cleanup
barrel.close()
```

### Range Queries (CritBit Mode)
```nim
var config = defaultBarrelConfig()
config.mode = bmCritBit
let barrel = openBarrel("data.db", config)

# Prefix search
for key in barrel.keysWithPrefix("user:"):
  echo key

# Range scan
for key in barrel.keysInRange("user:100", "user:200"):
  echo key

barrel.close()
```

### HugeBarrel for Massive Datasets
```nim
var config = defaultBarrelConfig()
config.mode = bmHugeCritBit
config.hugeConfig.maxEntriesPerRange = 500_000

var hb = openHugeBarrel("/path/to/hugebarrel", config)
defer hb.close()

# Works like regular barrel
discard hb.set("massive:key", "value")
echo hb.get("massive:key")

# Range management
echo hb.getRangeCount()
hb.flushAllRanges()
```

### Network Client
```nim
var client = newClient("localhost", 9876.Port)
defer client.close()

client.connect()
client.useBarrel("mydb")

# Basic operations
discard client.set("remote:key", "value")
echo client.get("remote:key")