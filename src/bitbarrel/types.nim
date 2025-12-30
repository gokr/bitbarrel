## Common types and constants for BitBarrel

import times

const
  MAGIC_NUMBER* = "BCKS"
  VERSION* = 1'u32
  HEADER_SIZE* = 32
  MAX_KEY_SIZE* = 64 * 1024  # 64KB
  MAX_VALUE_SIZE* = 32 * 1024 * 1024  # 32MB

type
  FileHeader* = object
    magic*: array[4, char]
    version*: uint32
    created*: int64
    fileSize*: uint64
    reserved*: array[8, byte]

  KeyDirEntry* = object
    ## Optimized in-memory index entry (24 bytes)
    ## - Removed timestamp: append-only ordering means position = ordering
    ## - Removed deleted: use valueSize == 0 as tombstone marker
    ## - Removed valuePos: calculate from recordPos + keyLen
    recordPos*: uint64   # 8 bytes - Position of record in file (after CRC)
    fileId*: uint32      # 4 bytes - Which data file contains the record
    valueSize*: uint32   # 4 bytes - Size of value (0 = tombstone/deleted)
    recordSize*: uint32  # 4 bytes - Total record size for compaction
    keyLen*: uint16      # 2 bytes - Key length for valuePos calculation

proc isDeleted*(entry: KeyDirEntry): bool =
  ## Check if entry is a tombstone (deleted record)
  entry.valueSize == 0

proc calcValuePos*(entry: KeyDirEntry): uint64 =
  ## Calculate value position from record position and key length
  ## Record format: [ts:8][keyLen:4][key:N][valLen:4][flags:1][algo:1][value]
  entry.recordPos + 8 + 4 + entry.keyLen.uint64 + 4 + 1 + 1

type
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

  CompactionState* = object
    inProgress*: bool             # Whether compaction is active
    startTime*: int64             # When compaction started (epoch timestamp)
    oldFileId*: uint32            # File being compacted
    newFileId*: uint32            # New file for writes + compacted data

  # Recovery configuration
  RecoveryConfig* = object
    enabled*: bool
    validateChecksums*: bool
    skipCorruptRecords*: bool
    autoRecovery*: bool

  # Barrel configuration (high-level API)
  ##
  ## **UserSyncMode** determines write durability:
  ## - `None`: Fastest, writes stay in OS buffer (risk of data loss on crash)
  ## - `Sync`: Writes flushed to OS buffer (good balance of speed and safety)
  ## - `Fsync`: Safest, writes sync to physical disk (slower)
  ##
  ## **BarrelMode** determines the index type:
  ## - `bmHash`: Hash table with O(1) lookups, no ordering (default)
  ## - `bmCritBit`: Ordered index supporting range/prefix queries
  ## - `bmHugeCritBit`: Two-tier architecture for massive datasets
  UserSyncMode* = enum
    None = "none"       # No sync (fastest, risk of data loss on system crash)
    Sync = "sync"       # Sync to OS buffer (good speed/safety balance)
    Fsync = "fsync"     # Sync to disk (safest, slower)

  BarrelMode* = enum
    bmHash         # Hash table - O(1) lookup, no ordering
    bmCritBit      # CritBit tree - O(key_len), supports range/prefix queries
    bmHugeCritBit  # Two-tier for massive datasets with range queries

  HugeBarrelConfig* = object
    maxEntriesPerRange*: int      # Max entries per RangeKeyDir (default: 100_000)
    rangeCacheSize*: int          # Max RangeKeyDirs in memory (default: 10)
    rangesPerFile*: int           # Max RangeKeyDirs per Barrel2 file (default: 100)
    maxDataFileSizeMB*: int       # Deprecated - file size naturally bounded by rangesPerFile
    autoSplitEnabled*: bool       # Enable automatic range splitting (default: true)
    flushIntervalMs*: int         # Time-based flush interval in ms (default: 1000, 0 = disabled)
    enableBarrel2Recovery*: bool  # Enable Barrel2 recovery on startup (default: true)

  BarrelConfig* = object
    # Storage config
    writeBufferSize*: int
    syncMode*: UserSyncMode
    autoCompact*: bool
    compactThreshold*: float
    compactInterval*: int   # Seconds between compaction checks (default: 60)
    validateCrc*: bool  # Validate CRC32 on reads (default: true)
    compressionConfig*: ptr CompressionConfig  # Compression settings (nil = use defaults)
    # TTL configuration
    defaultTtl*: int        # Default TTL in seconds (0 = no expiration)
    checkExpirationOnRead*: bool  # Check expiration during get() calls
    deleteExpiredOnRead*: bool   # Write tombstone when expired record is read
    # Index mode
    mode*: BarrelMode
    # HugeBarrel configuration (only used when mode = bmHugeCritBit)
    hugeConfig*: HugeBarrelConfig

  # Range partition types (used by bmHugeCritBit)
  RangeId* = uint32

  AccessModel* = enum
    amHash = "hash"
    amCritBit = "critbit"

  RangeMetadata* = object
    id*: RangeId
    keyCount*: int64
    lastAccess*: int64
    hintPath*: string
    isLoaded*: bool
    isDirty*: bool
    minKey*: string
    maxKey*: string
    accessModel*: AccessModel

  RangeManagementConfig* = object
    enabled*: bool
    splitThresholdKeys*: int = 50_000
    mergeThresholdKeys*: int = 10_000
    maxRangeSizeHintMB*: int = 100
    minRangeSizeHintMB*: int = 1
    autoSplit*: bool = true
    autoMerge*: bool = true
    compactOnSplit*: bool = false
    healthCheckInterval*: int = 300

  # RangeKeyDir entry for bmHugeCritBit mode
  RangeKeyDirEntry* = object
    key*: string           # The key (stored in range entries)
    recordPos*: uint64     # Position of record in file
    fileId*: uint32        # Which data file contains the record
    valueSize*: uint32     # Size of value (0 = tombstone/deleted)
    recordSize*: uint32    # Total record size for compaction
    keyLen*: uint16        # Key length for valuePos calculation

proc isDeleted*(entry: RangeKeyDirEntry): bool =
  ## Check if entry is a tombstone (deleted record)
  entry.valueSize == 0

proc calcValuePos*(entry: RangeKeyDirEntry): uint64 =
  ## Calculate value position from record position and key length
  entry.recordPos + 8 + 4 + entry.keyLen.uint64 + 4 + 1 + 1

type
  # Barrel2 recovery configuration (for HugeBarrel)
  Barrel2RecoveryOptions* = object
    validateChecksums*: bool      # Validate CRC32 on each record (default: true)
    skipCorruptRecords*: bool     # Skip bad records vs abort (default: true)
    maxProgressInterval*: int     # Report progress every N records (default: 10000)
    enableVerboseLogging*: bool   # Detailed logging (default: false)

  # Barrel2 recovery statistics
  Barrel2RecoveryStats* = object
    filesScanned*: int            # Number of data files scanned
    totalRecords*: int            # Total records read
    validRecords*: int            # Records with valid CRC32
    corruptRecords*: int          # Records with invalid CRC32
    tombstoneRecords*: int        # Deleted records (empty value)
    orphanedRecords*: int         # Records not in any RangeKeyDir
    recoveredRecords*: int        # Records successfully recovered
    bytesScanned*: int64          # Total bytes scanned
    recoveryTimeMs*: int64        # Recovery duration in milliseconds
    rangesCreated*: int           # New RangeKeyDirs created
    rangesUpdated*: int           # Existing RangeKeyDirs updated

  # Pending split marker for atomic split operations
  PendingSplit* = object
    oldRangeKey*: string
    leftRangeKey*: string
    rightRangeKey*: string
    timestamp*: int64
