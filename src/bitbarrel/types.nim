## Common types and constants for BitBarrel

import times

const
  MAGIC_NUMBER* = "BCKS"
  VERSION* = 1'u32
  HEADER_SIZE* = 32
  MAX_KEY_SIZE* = 64 * 1024  # 64KB
  MAX_VALUE_SIZE* = 1 * 1024 * 1024  # 1MB

type
  FileHeader* = object
    magic*: array[4, char]
    version*: uint32
    created*: int64
    fileSize*: uint64
    reserved*: array[8, byte]

  KeyDirEntry* = object
    fileId*: uint32      # Which data file contains the record
    recordPos*: uint64   # Position of record in file (after CRC)
    valuePos*: uint64    # Position of value within file
    valueSize*: uint32   # Size of value
    timestamp*: int64    # For conflict resolution and TTL
    recordSize*: uint32  # Total record size for merge decisions
    deleted*: bool       # True if this entry is a tombstone (deleted)

  # Write buffering configuration
  SyncMode* = enum
    syncImmediate    # Sync on every write (current behavior)
    syncBuffered    # Buffer in memory, sync periodically
    syncBatched     # Sync every N writes
    syncTimeBased    # Sync every X milliseconds

  # Compression configuration
  CompressionLevel* = enum
    clDefault        # Default compression level
    clFast          # Fast compression (less efficient)
    clBest          # Best compression (slower)

  CompressionConfig* = object
    enabled*: bool             # Enable/disable compression
    threshold*: int            # Minimum size to attempt compression (default: 256)
    level*: CompressionLevel   # Compression level

  BufferedEntry* = object
    key*: string
    value*: string
    timestamp*: int64
    whenReady*: proc(key: string, value: string, timestamp: int64)  # Callback

  WriteBufferStats* = object
    entriesWritten*: int64
    buffersFlushed*: int64
    entriesDropped*: int64
    maxBufferDepth*: int

  Command* = enum
    cmdGet = 0x01
    cmdSet = 0x02
    cmdDelete = 0x03
    cmdExists = 0x04
    cmdScan = 0x05
    cmdStats = 0x06

  # Compaction configuration
  CompactConfig* = object
    enabled*: bool
    triggerThreshold*: float    # Fragmentation threshold to trigger compact (0.0-1.0)
    compactInterval*: int       # Seconds between automatic compact checks
    compactIntervalBytes*: int64 # Bytes written between compact checks
    maxFileSize*: uint64        # Maximum file size before forcing compaction

  FileState* = enum
    fsActive     # Currently writable

  FileInfo* = object
    path*: string               # Full path to file
    id*: uint32                # File ID
    size*: uint64                # Current file size
    state*: FileState            # Current state
    created*: Time               # Creation timestamp
    lastModified*: Time           # Last modification
    totalRecords*: int           # Total records in file
    liveRecords*: int            # Active (non-deleted) records

  CompactStats* = object
    recordsScanned*: int          # Total records scanned during compact
    recordsKept*: int             # Records written to new file
    recordsDropped*: int          # Tombstones and expired records removed
    bytesScanned*: int64          # Bytes read from original file
    bytesWritten*: int64          # Bytes written to new file
    timeStarted*: Time
    timeCompleted*: Time

  # Recovery configuration
  RecoveryConfig* = object
    enabled*: bool
    validateChecksums*: bool
    skipCorruptRecords*: bool
    checkpointInterval*: int
    checkpointSizeThreshold*: int64
    maxIncrementalCheckpoints*: int
    autoRecovery*: bool

  # Checkpoint configuration
  CheckpointConfig* = object
    enabled*: bool
    interval*: int
    sizeThreshold*: int64
    maxIncremental*: int
    compressionEnabled*: bool

  # Barrel configuration (high-level API)
  UserSyncMode* = enum
    None = "none"       # No sync (fastest, risk of data loss)
    Sync = "sync"       # Sync to OS buffer
    Fsync = "fsync"     # Sync to disk (safest)

  BarrelMode* = enum
    bmNormal       # Hash table - O(1) lookup, no ordering
    bmCritBit      # CritBit tree - O(key_len), supports range/prefix queries
    bmRangedHash   # Hash-based lazy-loaded partitions for massive datasets
    bmRangedCritBit # CritBit-based lazy-loaded partitions with ordered ranges

  # Access models for ranged modes
  AccessModel* = enum
    amHash     # Hash-based range index (O(1) lookup)
    amCritBit  # CritBit-based range index (supports range/prefix queries)

  BarrelConfig* = object
    # Storage config
    writeBufferSize*: int
    syncMode*: UserSyncMode
    autoCompact*: bool
    compactThreshold*: float
    validateCrc*: bool  # Validate CRC32 on reads (default: true)
    # TTL configuration
    defaultTtl*: int        # Default TTL in seconds (0 = no expiration)
    checkExpirationOnRead*: bool  # Check expiration during get() calls
    deleteExpiredOnRead*: bool   # Write tombstone when expired record is read
    # Index mode
    mode*: BarrelMode
    # Range mode options
    rangeAccessModel*: AccessModel   # Auto-inferred from mode if not specified
    numRanges*: int           # Hash partitions (default: 100)
    maxLoadedRanges*: int     # Max partitions in memory (default: 10)

  # Range partition types (for bmRanged mode)
  RangeId* = uint32

  RangeMetadata* = object
    id*: RangeId
    keyCount*: int64
    lastAccess*: int64
    hintPath*: string
    isLoaded*: bool
    isDirty*: bool
    # Only used by CritBit ranges
    accessModel*: AccessModel
    # Key bounds for ordered range partitioning (used by bmRangedCritBit)
    minKey*: string          # Smallest key in this range (inclusive)
    maxKey*: string          # Largest key in this range (inclusive)
