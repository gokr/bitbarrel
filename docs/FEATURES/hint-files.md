# Hint Files in BitBarrel

Hint files are companion metadata files that enable fast database recovery (40,000+ keys/second) by storing only key location information, not values. They act as shortcuts for rebuilding the `KeyDir` index without scanning gigabytes of data files.

## Overview

- **Fast recovery**: 40,000+ keys/second recovery speed (5-10× faster than full scan)
- **Metadata-only**: Store key positions, not values - much smaller than data files
- **Per-data-file**: Each data file (`.data`) has a corresponding hint file (`.hint`)
- **Crash safe**: Atomic file operations ensure hint files are consistent
- **Optional but recommended**: Recovery works without hint files but much slower
- **Incremental recovery**: Version 2 hint files support scanning only new data since hint creation

## Why "Hint" Files?

The name comes from Bitcask terminology—they provide "hints" about where keys are located in data files. Think of them as an index or map that tells the recovery system: "Key X is at position Y in data file Z."

### Comparison: Hint Files vs. Data Files
| Aspect | Hint Files | Data Files |
|--------|------------|------------|
| Content | Key metadata only | Full records (keys + values) |
| Size | ~40 bytes per key | Full record size (key + value + overhead) |
| Purpose | Fast index rebuild | Actual data storage |
| Recovery speed | 68K+ keys/sec | 4K-8K keys/sec (full scan) |
| Generated | After compaction | All writes go here |
| Format | Version 1: 32-byte header<br>Version 2: 48-byte header | 32-byte fixed header |

## Hint File Format - Version 2

BitBarrel uses version 2 hint files as the current format, with backward compatibility for version 1.

### Hint File Header (Version 2: 48 bytes)
```
Offset  Size  Field        Description
0       4     magic        Magic bytes: ['H', 'I', 'N', 'T']
4       4     version      Format version (currently 2)
8       8     timestamp    Creation timestamp (Unix epoch)
16      4     entryCount   Number of entries in hint file
20      4     dataFileId   Associated data file ID (e.g., 000001)
24      8     lastScanPos  Byte offset where hint file stopped scanning
32      8     dataFileSize  Size of data file when hint was created
40      4     crc32        Header CRC32 checksum (covers first 40 bytes)
44      4     reserved     Reserved for future use
```

### Version 1 Header (for backward compatibility: 32 bytes)
```
Offset  Size  Field        Description
0       4     magic        Magic bytes: ['H', 'I', 'N', 'T']
4       4     version      Format version (1)
8       8     timestamp    Creation timestamp (Unix epoch)
16      4     entryCount   Number of entries in hint file
20      4     dataFileId   Associated data file ID (e.g., 000001)
24      4     crc32        Header CRC32 checksum
28      4     reserved     Reserved for future use
```

**Key changes in Version 2:**
- Added `lastScanPos` and `dataFileSize` fields for incremental recovery
- Header size increased from 32 to 48 bytes
- CRC covers first 40 bytes instead of 28 bytes

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

```nim.compilable
type
  HintHeader* = object
    magic*: array[4, char]      # "HINT"
    version*: uint32            # Version number
    timestamp*: int64           # Creation timestamp
    entryCount*: uint32         # Number of entries
    dataFileId*: uint32         # Associated data file ID
    lastScanPos*: uint64        # Byte offset where scan stopped (v2+)
    dataFileSize*: uint64       # Data file size at creation (v2+)
    crc32*: uint32              # Header checksum
    reserved*: array[8, byte]   # Reserved for future use

  HintEntry* = object
    key*: string                # Key string
    recordPos*: uint64          # Position of record in data file (CRC position)
    valueSize*: uint32          # Size of value (0 = tombstone/deleted)
    recordSize*: uint32         # Total record size
```

**Note:** The HintEntry structure is optimized - value position is calculated from recordPos and key length, timestamp ordering is implicit (append-only), and deletion is indicated by valueSize == 0.

## Incremental Recovery (Version 2)

Version 2 hint files enable incremental recovery, which prevents data loss in critical scenarios.

### How It Works

When a system crashes after a hint file was created but before new data was flushed to disk:

1. **Load hint file entries** into KeyDir (fast metadata-only operation)
2. **Check file size** - if current data file is larger than hint's `dataFileSize`
3. **Scan only the tail** - from `lastScanPos` to end of file
4. **Merge with hint entries** - newer timestamps win (prevents stale data)

### Example Scenario

```
Timeline:
1. Hint file created at byte offset 1000 (records: key1, key2)
2. More writes occur, file grows to 2000 bytes (adds: key3, key4)
3. System crashes

Recovery with v2 hint file:
1. Load hint file entries (key1, key2 from position 0-1000)
2. Detect dataFileSize (1000) < currentFileSize (2000)
3. Scan tail from offset 1000-2000
4. Retrieve key3, key4 from tail
5. All 4 keys recovered
```

**Without incremental recovery (v1):** key3 and key4 would be lost.

### Code Example

```nim
proc recoverFromHintFile*(engine: RecoveryEngine, filePath: string): bool =
  ## Attempt recovery using hint file with incremental scan

  # Load hint file
  let (header, entries, success) = readHintFile(hintPath)

  # Load entries into KeyDir
  loadKeyDirFromHint(hintPath, engine.keyDir)

  # Incremental recovery: scan tail if file grew
  if header.version >= 2 and currentFileSize > header.lastScanPos:
    scanFileFromPosition(filePath, header.lastScanPos, currentFileSize)

  return true
```

### When Hint Files Are Created

Hint files are currently generated:
1. **After compaction**: New data files get corresponding hint files automatically
2. **On barrel close**: Hint file generated before closing to capture all data

### Recovery Process

The recovery engine (`src/storage/recovery.nim`) handles both version 1 and version 2 hint files:

**For v2 hint files:**
1. Load hint file entries into KeyDir
2. If data file grew after hint creation, scan only the new tail
3. Statistics track: `hintFilesUsed`, `filesFromHint`, `totalRecords`

**For v1 hint files:**
1. Load hint file entries into KeyDir (no incremental scan)
2. Falls back to full scan if data file is newer than hint
3. Recovery still works, but may need to scan entire file

## Performance Characteristics

### Recovery Performance
- **With v2 hint files (no new data)**: 40,000+ keys/second (memory/CPU bound)
- **With v2 hint files (with new data tail)**: 40,000+ core keys + tail scan (fast)
- **Without hint files**: 4,000-8,000 keys/second (disk I/O bound)
- **Speedup**: 5-10× faster recovery

### Space Overhead
- **Per key**: ~40 bytes (vs. full record which can be kilobytes)
- **v2 header overhead**: +16 bytes per hint file (for incremental recovery)
- **Typical ratio**: Hint files are 1-5% the size of data files

### Generation Cost
- **Write overhead**: Minimal - sequential write after file operations
- **Compaction overhead**: Required during compaction (already doing disk I/O)
- **Memory usage**: Temporary buffers during generation (~50MB for 1M keys)

## Specialized Hint Files

### Range Hint Files (`rangehint.nim`)
For `bmHugeCritBit` mode with partitioned datasets:
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
recovery:
  use_hint_files: true           # Enable hint file usage (default: true)
  validate_hint_files: true      # Validate CRC32 on load (default: true)
```

## Best Practices

1. **Keep hint files**: Never delete `.hint` files - they're essential for fast recovery
2. **Generate for existing data**: Hint files are created after compaction
3. **Validate periodically**: Check hint file integrity during maintenance
4. **Backup with data files**: Always backup hint files with their corresponding data files
5. **Upgrade to v2**: v2 hint files provide better data safety with incremental recovery

## Troubleshooting

### Missing Hint Files
- Check if `useHintFiles` is enabled in configuration
- Verify file permissions in data directory
- Check that compaction has run (hint files created after compaction)
- Recovery works without hint files, just slower

### Corrupted Hint Files
- Enable `validateHintFiles` to detect corruption early
- Delete corrupted hint files - recovery will scan data file instead
- Check disk integrity if hint files frequently corrupt
- Consider filesystem issues (power loss, bad sectors)

### Missing Data After Recovery
- Verify you're using v2 hint files for incremental recovery
- Check logs for "Scanning new bytes from..." messages
- v1 hint files don't support incremental recovery

### Slow Recovery
- Verify hint files exist for all data files
- Check if recovery is falling back to full scans (`filesFromScan` in stats)
- Monitor disk I/O during recovery
- Ensure v2 hint files are being generated

## API Reference

The hint file API is available in `src/storage/hintfile.nim`:

```nim
# Write a v2 hint file
let entries = @[HintEntry(key: "user:1", recordPos: 100, valueSize: 50, recordSize: 70)]
let dataFileSize = getFileSize("000001.data")
let success = writeHintFile("000001.hint", 1'u32, entries, dataFileSize)

# Read a hint file (supports v1 and v2)
let (header, entries, success) = readHintFile("000001.hint")

# Validate a hint file
if validateHintFile("000001.hint"):
  echo "Hint file is valid (version ", header.version, ")"
```

## Testing

Run hint file tests:

```bash
# Test hint file I/O
nim c -r tests/recovery/test_hintfile.nim

# Test recovery with hint files
nim c -r tests/recovery/test_recovery.nim

# Run all recovery tests
nimble testRecovery
```

## Migration and Compatibility

- **Version compatibility**: Hint files are versioned; v2 reads both v1 and v2 formats
- **v1 compatibility**: Old v1 hint files still work, but don't support incremental recovery
- **Missing hint files**: Recovery works without them (slower, but safe)
- **Regeneration**: Hint files can always be regenerated from data files
- **Cross-platform**: Hint files are binary compatible across platforms (same endianness)
- **Backup/restore**: Must preserve `.hint` → `.data` file relationships

## Version History

### Version 2 (Current) - 2025-12-26
- Added `lastScanPos` field for incremental recovery
- Added `dataFileSize` field to track data file size at hint creation
- Header size increased from 32 to 48 bytes
- Prevents data loss when crashes occur after hint generation
- Backward compatible with v1 hint files

### Version 1 (Legacy)
- Basic hint file format with 32-byte header
- Full hint file or full scan recovery
- If data file grew after hint creation, entire file rescanned
