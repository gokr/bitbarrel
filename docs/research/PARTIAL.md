# Front Truncation Compaction Implementation Plan

## Executive Summary

Yes, front file truncation is possible on Linux using `FALLOC_FL_COLLAPSE_RANGE`, but it has limitations. This plan implements partial compaction that scans the first N% of a datafile, moves live records to the end, and truncates the beginning.

## Research Findings

### Front Truncation Support
- **Linux 3.15+**: Supports `FALLOC_FL_COLLAPSE_RANGE` - exactly what we need
- **Requirements**: Page-aligned offsets (4KB boundaries)
- **Filesystem Support**: ext4, XFS, Btrfs (most modern filesystems)
- **Limitation**: Cannot truncate arbitrary ranges, must be page-aligned

### Implementation Requirements
1. **Alignment Handling**: Must align truncation points to 4KB boundaries
2. **Position Updates**: All KeyDir positions must be adjusted after truncation
3. **Crash Safety**: Need journaling for partial operations
4. **Fallback Strategy**: Copy-rewrite method for unsupported systems

## Implementation Plan

### Phase 1: Core Infrastructure

#### 1.1 Add Linux System Call Wrapper (`src/storage/syscalls.nim`)
```nim
when defined(linux):
  const
    FALLOC_FL_KEEP_SIZE = 0x01
    FALLOC_FL_PUNCH_HOLE = 0x02
    FALLOC_FL_COLLAPSE_RANGE = 0x08
    FALLOC_FL_ZERO_RANGE = 0x10

  proc fallocate*(fd: cint, mode: cint, offset: int64, len: int64): cint {.
    importc, header: "<fcntl.h>", discardable.}

  proc collapseRange*(fd: cint, offset: int64, len: int64): bool =
    result = fallocate(fd, FALLOC_FL_COLLAPSE_RANGE, offset, len) == 0
```

#### 1.2 Extend DataFile Module (`src/storage/datafile.nim`)
```nim
# Add alignment utilities
proc alignToPageBoundary*(size: uint64, pageSize: uint32 = 4096): uint64 =
  ((size + pageSize.uint64 - 1) div pageSize.uint64) * pageSize.uint64

# Add collapse range support
proc collapseRange*(df: DataFile, offset: uint64, length: uint64): bool =
  when defined(linux):
    result = collapseRange(df.file.handle, offset.int64, length.int64)
  else:
    result = false

# Add position update helpers
proc copyRecordsFromOffset*(df: DataFile, offset: uint64): Iterator[RecordData]
```

### Phase 2: Partial Compaction Module (`src/storage/partialcompact.nim`)

#### 2.1 Core Algorithm
```nim
type
  PartialCompactConfig* = object
    enabled*: bool
    scanPercentage*: float      # Default: 0.10 (10%)
    minFileSize*: uint64        # Only files > X bytes
    alignmentSize*: uint32      # Page size (default: 4096)

  LiveRecord* = object
    key*: string
    value*: string
    timestamp*: int64
    oldPos*: uint64

proc partialCompact*(controller: CompactController,
                    file: FileInfo,
                    config: PartialCompactConfig): bool =
  # Phase 1: Scan first N% for live records
  let scanLimit = alignToPageBoundary(
    HEADER_SIZE.uint64 + uint64(file.size.float * config.scanPercentage)
  )

  var liveRecords: seq[LiveRecord] = @[]
  var df = datafile.open(file.path, file.id)

  # Scan and collect
  for record in df.scanRange(HEADER_SIZE.uint64, scanLimit):
    if isRecordLive(controller.keyDir, record.key, record.timestamp):
      liveRecords.add(LiveRecord(
        key: record.key,
        value: record.value,
        timestamp: record.timestamp,
        oldPos: record.pos
      ))

  # Phase 2: Move live records to end
  for record in liveRecords:
    let newPos = df.appendRecord(record.key, record.value, record.timestamp)
    controller.keyDir.updatePosition(record.key, newPos)

  df.sync()

  # Phase 3: Truncate beginning
  let truncationSize = scanLimit - HEADER_SIZE.uint64
  if not df.collapseRange(0, truncationSize):
    return fallbackPartialCompact(df, truncationSize)

  # Phase 4: Update remaining positions
  controller.keyDir.adjustPositions(file.id, truncationSize)
  true
```

#### 2.2 Fallback Implementation
```nim
proc fallbackPartialCompact(df: DataFile, truncationSize: uint64): bool =
  # Copy-rewrite approach for unsupported systems
  let tempPath = df.path & ".partial.tmp"
  var newFile = datafile.open(tempPath, df.id)

  # Copy header
  let header = df.readHeader()
  newFile.writeHeader(header)

  # Copy remaining data after truncation point
  df.copyRangeToFile(newFile, truncationSize + HEADER_SIZE.uint64, df.size)

  # Atomic replacement
  df.close()
  newFile.close()

  when defined(posix):
    if rename(cstring(tempPath), cstring(df.path)) != 0:
      raiseOSError(osLastError())

  true
```

### Phase 3: Integration

#### 3.1 Update Compact Controller (`src/storage/compact.nim`)
```nim
type CompactControllerObj* = object
  # ... existing fields ...
  partialConfig*: PartialCompactConfig
  supportsCollapseRange*: bool

proc newCompactController*(config: types.CompactConfig,
                         keyDir: var KeyDir,
                         dataDir: string,
                         partialConfig: PartialCompactConfig = defaultPartialCompactConfig()): CompactController =
  # ... existing init ...

  # Detect collapse range support
  result.supportsCollapseRange = detectCollapseRangeSupport()

proc performCompact*(controller: CompactController, files: seq[types.FileInfo]) =
  # Sort by fragmentation or age
  let sortedFiles = prioritizeFiles(files)

  for file in sortedFiles:
    # Try partial compaction first for large files
    if controller.partialConfig.enabled and
       file.size > controller.partialConfig.minFileSize:
      if partialCompact(controller, file, controller.partialConfig):
        echo fmt"Partial compact completed for file {file.id}"
        continue

    # Fall back to full compaction
    performFullCompact(controller, file)
```

#### 3.2 Update Configuration (`src/bitbarrel/types.nim`)
```nim
type BarrelConfig* = object
  # ... existing fields ...
  # Partial compaction config
  partialCompactEnabled*: bool = true
  partialCompactPercentage*: float = 0.10
  partialCompactMinFileSize*: uint64 = 16 * 1024 * 1024  # 16MB
```

#### 3.3 Update KeyDir for Batch Operations (`src/storage/keydir.nim`)
```nim
proc adjustPositions*(keyDir: var KeyDir, fileId: uint32, offset: uint64) =
  withLock(keyDir.lock):
    for entry in keyDir.entries.mvalues:
      if entry.fileId == fileId and entry.recordPos > offset:
        entry.recordPos -= offset
        entry.valuePos -= offset

proc updatePosition*(keyDir: var KeyDir, key: string, newPos: tuple[pos: uint64, valuePos: uint64]) =
  withLock(keyDir.lock):
    if key in keyDir.entries:
      keyDir.entries[key].recordPos = newPos.pos
      keyDir.entries[key].valuePos = newPos.valuePos
```

### Phase 4: Testing (`tests/test_partial_compact.nim`)

```nim
suite "Partial Compaction Tests":
  test "Partial compact with live records at beginning":
    # Create test file with live records in first 10%
    # Run partial compact
    # Verify records moved and file truncated

  test "Partial compact with page alignment":
    # Test alignment requirements are handled

  test "Fallback on unsupported systems":
    # Test copy-rewrite fallback

  test "Crash recovery":
    # Test intent file recovery
```

### Phase 5: Benchmarking (`bench/partial_compact_bench.nim`)

Test scenarios:
1. 10% fragmentation at beginning of 100MB file
2. 50% fragmentation at beginning of 1GB file
3. Full file with empty first 20%
4. Compare with full compaction performance

## Implementation Priority

1. **High**: Core partial compact algorithm
2. **High**: Linux fallocate wrapper
3. **Medium**: KeyDir batch update support
4. **Medium**: Integration with compact controller
5. **Low**: Crash recovery journaling
6. **Low**: Configuration options

## Benefits

1. **Reduced I/O**: Only rewrites up to N% + moved records, not entire file
2. **Faster**: Less data movement than full compaction
3. **Incremental**: Can run more frequently on large files
4. **Space Efficient**: Frees space incrementally

## Limitations

1. **Linux Only**: FALLOC_FL_COLLAPSE_RANGE is Linux-specific
2. **Alignment**: Must pad to 4KB boundaries
3. **Fragmentation**: May leave small gaps
4. **Complexity**: More complex than full compaction

## Conclusion

Partial compaction with front truncation is feasible and beneficial for BitBarrel:
- **Supported on Linux** with modern filesystems
- **Requires alignment** handling but manageable
- **Provides performance benefits** for large files with front fragmentation
- **Needs fallback** for universal compatibility

The implementation leverages Linux-specific features while maintaining portability through fallback mechanisms.