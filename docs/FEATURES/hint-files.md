# Hint Files in BitBarrel

Hint files are companion metadata files that enable fast database recovery (40,000+ keys/second) by storing only key location information, not values. They act as shortcuts for rebuilding the `KeyDir` index without scanning gigabytes of data files.

## Overview

- **Fast recovery**: 40,000+ keys/second recovery speed (5-10× faster than full scan)
- **Metadata-only**: Store key positions, not values - much smaller than data files
- **Per-data-file**: Each data file (`.data`) has a corresponding hint file (`.hint`)
- **Crash safe**: Atomic file operations ensure hint files are consistent
- **Optional but recommended**: Recovery works without hint files but much slower

## Why "Hint" Files?

The name comes from Bitcask terminology—they provide "hints" about where keys are located in data files. Think of them as an index or map that tells the recovery system: "Key X is at position Y in data file Z."

### Comparison: Hint Files vs. Data Files
| Aspect | Hint Files | Data Files |
|--------|------------|------------|
| Content | Key metadata only | Full records (keys + values) |
| Size | ~50 bytes per key | Full record size (key + value + overhead) |
| Purpose | Fast index重建 | Actual data storage |
| Recovery speed | 40K+ keys/sec | 4K-8K keys/sec (full scan) |
| Generated | Automatically during write/merge | All writes go here |

## Relationship with Checkpoint System

BitBarrel has **two complementary systems** for fast recovery:

### Checkpoint System
- **Files**: `.cpt` (full) and `.inc` (incremental) checkpoint files
- **Content**: Complete `KeyDir` index persistence (all keys across all data files)
- **Purpose**: Load entire index from checkpoint without any data file scanning
- **Location**: Separate checkpoint directory (configurable)
- **Recovery flow**: Primary recovery path - load checkpoint first if available

### Hint Files
- **Files**: `.hint` files (one per data file)
- **Content**: Key metadata for specific data file only
- **Purpose**: Rebuild `KeyDir` from metadata without scanning full data files
- **Location**: Same directory as corresponding `.data` files
- **Recovery flow**: Secondary recovery path - used when checkpoints unavailable

### How They Work Together
1. **Recovery priority**: Checkpoints → Hint files → Full data file scan
2. **Checkpoint available**: Load entire `KeyDir` from checkpoint (fastest)
3. **No checkpoint**: Use hint files to rebuild `KeyDir` (still fast: 40K+ keys/sec)
4. **No hint files**: Fall back to full data file scan (slowest)

### Combined Benefits
- **Maximum recovery speed**: Checkpoints provide instant index loading
- **Redundancy**: Hint files provide backup recovery method
- **Flexibility**: Can use either system independently
- **Performance**: Both contribute to the 40K+ keys/sec recovery speeds in README

## File Format

### Hint File Header (32 bytes)
```
Offset  Size  Field        Description
0       4     magic        Magic bytes: ['H', 'I', 'N', 'T']
4       4     version      Format version (currently 1)
8       8     timestamp    Creation timestamp (Unix epoch)
16      4     entryCount   Number of entries in hint file
20      4     dataFileId   Associated data file ID (e.g., 000001)
24      4     crc32        Header CRC32 checksum
28      4     reserved     Reserved for future use
```

### Entry Format
Each entry consists of:
1. Key length (2 bytes, unsigned)
2. Key bytes (variable length)
3. Record position in data file (8 bytes, unsigned)
4. Value position within record (8 bytes, unsigned)
5. Value size (4 bytes, unsigned)
6. Timestamp (8 bytes, signed)
7. Record size (4 bytes, unsigned)
8. Deleted flag (1 byte, boolean)

Total: 35 bytes fixed + key length variable

## Implementation Details

### Core Module
Hint files are implemented in `src/storage/hintfile.nim`:

```nim
type
  HintHeader* = object
    magic*: array[4, char]      # "HINT"
    version*: uint32            # Version number
    timestamp*: int64           # Creation timestamp
    entryCount*: uint32         # Number of entries
    dataFileId*: uint32         # Associated data file ID
    crc32*: uint32              # Header checksum
    reserved*: array[4, byte]

  HintEntry* = object
    key*: string                # Key string
    recordPos*: uint64          # Position of record in data file
    valuePos*: uint64           # Position of value within record
    valueSize*: uint32          # Size of value
    timestamp*: int64           # Record timestamp
    recordSize*: uint32         # Total record size
    deleted*: bool              # True if this is a tombstone
```

### Hint File Generation
Hint files are automatically created:

1. **During merge/compaction**: New data files get corresponding hint files
2. **On-demand**: Can be generated for existing data files via utility
3. **Background**: Low-priority task during idle periods

### Recovery Process
The recovery engine (`src/storage/recovery.nim`) prioritizes hint files:

```nim
proc recoverFromHintFile*(engine: RecoveryEngine, filePath: string): bool =
  ## Attempt to recover using a hint file (much faster than full scan)
  let hintPath = getHintPath(filePath)

  if not hintFileExists(hintPath):
    return false  # Fall back to full scan

  # Validate and load hint file
  if validateHintFile(hintPath):
    engine.stats.hintFilesUsed += 1
    return loadKeyDirFromHint(hintPath, engine.keyDir) >= 0
  else:
    engine.stats.hintFilesInvalid += 1
    return false
```

**Recovery flow**:
1. Check for hint file for each data file
2. If valid hint file exists, load keys from it (fast path)
3. If no hint file or invalid, scan data file (slow path)
4. Statistics track: `hintFilesUsed`, `filesFromHint`, `filesFromScan`

## Performance Characteristics

### Recovery Performance
- **With hint files**: 40,000+ keys/second (memory/CPU bound)
- **Without hint files**: 4,000-8,000 keys/second (disk I/O bound)
- **Speedup**: 5-10× faster recovery

### Space Overhead
- **Per key**: ~50 bytes (vs. full record which can be kilobytes)
- **Typical ratio**: Hint files are 1-5% the size of data files
- **Compression**: Hint files are not compressed (already minimal size)

### Generation Cost
- **Write overhead**: Minimal - appends to hint file during data writes
- **Merge overhead**: Required during compaction (already doing disk I/O)
- **Memory usage**: Temporary buffers during generation

## Specialized Hint Files

### Range Hint Files (`rangehint.nim`)
For `bmRangedCritBit` mode with partitioned datasets:
- Magic: `['R', 'H', 'N', 'T']`
- Associates entries with specific `rangeId`
- Enables lazy loading/unloading of range partitions

### CritBit Hint Files (`critbithint.nim`)
For `bmCritBit` mode with sorted key trees:
- Magic: `['C', 'H', 'N', 'T']`
- Stores CritBitIndex structure for range queries

## Configuration

Hint file behavior is controlled by configuration:

```yaml
storage:
  data_dir: "./data"
  recovery:
    use_hint_files: true           # Enable hint file usage (default: true)
    validate_hint_files: true      # Validate CRC32 on load (default: true)
    generate_missing_hints: true   # Generate missing hint files on recovery (default: false)
    hint_file_compression: false   # Not currently supported
```

## Best Practices

1. **Keep hint files**: Never delete `.hint` files - they're essential for fast recovery
2. **Generate for existing data**: Use `nim c -r examples/hintfile_generator.nim` to create hint files for legacy data
3. **Validate periodically**: Check hint file integrity during maintenance
4. **Backup with data files**: Always backup hint files with their corresponding data files
5. **Monitor generation**: Ensure new data files get hint files (check logs)

## Troubleshooting

### Missing Hint Files
- Check if `use_hint_files` is enabled in configuration
- Verify file permissions in data directory
- Check logs for hint file generation errors
- Generate missing hint files with utility tool

### Corrupted Hint Files
- Enable `validate_hint_files` to detect corruption early
- Delete corrupted hint files - they'll be regenerated from data file
- Check disk integrity if hint files frequently corrupt
- Consider filesystem issues (power loss, bad sectors)

### Slow Recovery
- Verify hint files exist for all data files
- Check if recovery is falling back to full scans (`filesFromScan` in stats)
- Monitor disk I/O during recovery
- Consider generating hint files in advance

## API Reference

The hint file API is available in `src/storage/hintfile.nim`:

```nim
# Write a hint file
let entries = @[HintEntry(key: "user:1", recordPos: 0, valuePos: 20, ...)]
let success = writeHintFile("000001.hint", entries, 1'u32)

# Read a hint file
let (header, entries) = readHintFile("000001.hint")

# Validate a hint file
if validateHintFile("000001.hint"):
  echo "Hint file is valid"

# Generate hint file from data file
let count = generateHintFileFromData("000001.data", "000001.hint")
echo "Generated hint file with ", count, " entries"
```

## Testing

Run hint file tests:

```bash
# Test hint file I/O
nim c -r --path:src tests/test_hintfile.nim

# Test recovery with hint files
nim c -r --path:src tests/test_recovery.nim

# Test hint file generation
nim c -r --path:src examples/hintfile_generator.nim

# Run all storage tests
nimble testStorage
```

## Migration and Compatibility

- **Version compatibility**: Hint files are versioned; old formats remain readable
- **Missing hint files**: Recovery works without them (slower)
- **Regeneration**: Hint files can always be regenerated from data files
- **Cross-platform**: Hint files are binary compatible across platforms (same endianness)
- **Backup/restore**: Must preserve `.hint` → `.data` file relationships