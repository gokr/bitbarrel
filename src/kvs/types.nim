## Common types and constants for the KVS implementation

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

  # Write buffering configuration
  SyncMode* = enum
    syncImmediate    # Sync on every write (current behavior)
    syncBuffered    # Buffer in memory, sync periodically
    syncBatched     # Sync every N writes
    syncTimeBased    # Sync every X milliseconds

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

  # Merge configuration
  MergeConfig* = object
    enabled*: bool
    maxFileSize*: uint64
    minFilesToMerge*: int
    triggerThreshold*: float
    maxMergeThreads*: int
    mergeInterval*: int
    mergeIntervalBytes*: int64
    skipThreshold*: int

  FileState* = enum
    fsActive     # Currently writable
    fsImmutable   # Read-only, candidate for merge
    fsMerging    # Currently being merged
    fsDeleted    # Marked for deletion

  FileInfo* = object
    path*: string               # Full path to file
    id*: uint32                # File ID
    size*: uint64                # Current file size
    state*: FileState            # Current state
    created*: Time               # Creation timestamp
    lastModified*: Time           # Last modification
    deleteCount*: int            # Number of deleted/tombstone records
    totalRecords*: int           # Total records in file
    duplicateCount*: int         # Superseded records
    liveRecords*: int            # Active (non-deleted) records

  MergeStats* = object
    filesProcessed*: int
    recordsScanned*: int
    recordsKept*: int
    recordsDropped*: int
    bytesScanned*: int64
    bytesWritten*: int64
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

