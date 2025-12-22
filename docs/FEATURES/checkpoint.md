# Checkpoint System in BitBarrel

The checkpoint system periodically persists the in-memory `KeyDir` index to disk, enabling faster database recovery by avoiding full data file scans. It supports both full and incremental checkpoints for efficient index persistence.

## Overview

- **Fast recovery**: Load `KeyDir` from checkpoint instead of scanning all data files
- **Two checkpoint types**: Full checkpoints (complete snapshot) and incremental checkpoints (changed keys only)
- **Crash safe**: Atomic file operations ensure checkpoints are consistent
- **Configurable**: Automatic checkpointing based on time and size thresholds
- **Performance impact**: Minimal overhead during normal operation

## Checkpoint Types

### Full Checkpoints (`.cpt` files)
- Complete snapshot of the entire `KeyDir` index
- Created periodically based on configuration
- Used as base for incremental checkpoints
- Magic header: `['C', 'K', 'P', 'T']`

### Incremental Checkpoints (`.inc` files)
- Store only keys changed since last full checkpoint
- Smaller and faster to write
- Applied on top of full checkpoints during recovery
- Magic header: `['C', 'K', 'P', 'T']` with different checkpoint type flag

## Configuration

### Runtime Configuration
Checkpoint behavior can be controlled via configuration:

```yaml
storage:
  data_dir: "./data"
  checkpoint:
    enabled: true                    # Enable checkpoint system
    interval: 300                    # Checkpoint interval in seconds (default: 300)
    size_threshold: 10485760         # Trigger checkpoint when estimated size > 10MB (default)
    incremental: true                # Use incremental checkpoints when possible
    checkpoint_dir: "./checkpoints"  # Directory for checkpoint files
```

### Environment Variables
```
BITBARREL_CHECKPOINT_ENABLED=true
BITBARREL_CHECKPOINT_INTERVAL=300
BITBARREL_CHECKPOINT_SIZE_THRESHOLD=10485760
BITBARREL_CHECKPOINT_INCREMENTAL=true
```

## File Format

### Checkpoint Header (64 bytes)
```
Offset  Size  Field          Description
0       4     magic          Magic bytes: ['C', 'K', 'P', 'T']
4       4     version        Format version (currently 1)
8       8     timestamp      Creation timestamp (Unix epoch)
16      4     keyCount       Number of keys in checkpoint
20      4     checkpointType String offset to type: "full" or "incremental"
24      4     baseCheckpoint String offset to base checkpoint (for incremental)
28      4     size           Checkpoint file size
32      4     crc32          Header CRC32 checksum
36      28    reserved       Reserved for future use
```

### Entry Format
Each entry consists of:
- Key length (2 bytes)
- Key bytes (variable)
- `KeyDirEntry` data (37 bytes):
  - File ID (4 bytes)
  - Record position (8 bytes)
  - Value position (8 bytes)
  - Value size (4 bytes)
  - Timestamp (8 bytes)
  - Record size (4 bytes)
  - Deleted flag (1 byte)

## Implementation Details

### Core Module
The checkpoint system is implemented in `src/storage/checkpoint.nim`:

```nim
type
  CheckpointMetadata* = object
    timestamp*: int64
    formatVersion*: uint32
    fileId*: uint32
    keyCount*: int
    checkpointType*: string  # "full", "incremental"
    baseCheckpoint*: string  # For incremental checkpoints
    size*: int64
    crc32*: uint32

  CheckpointSystem* = ref object
    dataDir*: string
    checkpointDir*: string
    options*: CheckpointOptions
    stats*: CheckpointStats
    lastCheckpoint*: string
    checkpointLock*: Lock
    isEnabled*: bool
```

### Automatic Checkpointing
The system automatically creates checkpoints based on:
1. **Time-based**: Every `checkpointInterval` seconds (default: 300s)
2. **Size-based**: When estimated `KeyDir` size exceeds `checkpointSizeThreshold` (default: 10MB)

Size estimation: `keyDir.len() * 100` bytes per key (approximate)

### Recovery Process
During database recovery (`src/storage/recovery.nim`):

1. **Check for latest checkpoint** in checkpoint directory
2. **Load full checkpoint** (`.cpt` file)
3. **Apply incremental checkpoints** (`.inc` files) in chronological order
4. **Fallback to hint files/data file scan** if no checkpoint available

## Performance Characteristics

### Write Performance
- **Checkpoint creation**: Minimal impact (background operation)
- **Memory usage**: Additional ~50 bytes per key during checkpoint creation
- **Disk space**: ~50-60 bytes per key in checkpoint files

### Recovery Performance
- **Checkpoint load**: ~10,000+ keys/second (memory-bound)
- **Compared to hint files**: Similar speed, but checkpoints include full `KeyDir`
- **Compared to full scan**: 10-100× faster for large databases

### Trade-offs
- **Checkpoints vs Hint files**:
  - Checkpoints: Complete `KeyDir`, faster to load, larger files
  - Hint files: Per-data-file metadata, smaller files, require data file scan
- **Full vs Incremental**:
  - Full: Simpler recovery, larger files
  - Incremental: Smaller files, requires chain of checkpoints

## Best Practices

1. **Enable checkpoints** for databases with >10,000 keys
2. **Use incremental checkpoints** for frequently updated databases
3. **Adjust interval** based on update frequency:
   - High update rate: 60-300 seconds
   - Low update rate: 300-3600 seconds
4. **Monitor checkpoint directory size** - old checkpoints can be archived/deleted
5. **Combine with hint files** for fastest possible recovery

## Troubleshooting

### Checkpoints Not Being Created
- Verify checkpoint system is enabled in configuration
- Check `checkpointInterval` and `size_threshold` values
- Ensure checkpoint directory is writable
- Check logs for checkpoint-related errors

### Recovery Fails with Checkpoint
- Ensure checkpoint chain is complete (full + all incremental)
- Check for corrupted checkpoint files (CRC32 validation)
- Verify checkpoint version compatibility
- Fall back to hint files if checkpoint recovery fails

### Large Checkpoint Files
- Consider more frequent incremental checkpoints
- Adjust `size_threshold` to trigger checkpoints earlier
- Monitor `KeyDir` size growth

## API Reference

The checkpoint API is available in `src/storage/checkpoint.nim`:

```nim
# Create a checkpoint system
var cp = newCheckpointSystem(dataDir, checkpointDir)

# Write a checkpoint
let success = cp.writeCheckpoint(keyDir, "full")

# Load a checkpoint
let loadedKeys = cp.loadCheckpoint("checkpoint.cpt", keyDir)

# Get checkpoint statistics
let stats = cp.getStats()
echo "Checkpoints created: ", stats.checkpointsCreated
echo "Keys checkpointed: ", stats.keysCheckpointed
```

## Testing

Run checkpoint-related tests:

```bash
# Test checkpoint system
nim c -r --path:src tests/test_checkpoint.nim

# Test recovery with checkpoints
nim c -r --path:src tests/test_recovery.nim

# Run all storage tests
nimble testStorage
```

## Migration and Compatibility

- **Version compatibility**: Checkpoints are versioned; old checkpoints remain readable
- **Disabling checkpoints**: Safe to disable - recovery will use hint files/data scan
- **Changing configuration**: New checkpoints reflect updated settings; old checkpoints remain valid
- **Directory structure**: Checkpoints can be moved/archived independently of data files