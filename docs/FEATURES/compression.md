# Compression Support in BitBarrel

BitBarrel supports configurable compression for record values to reduce storage size and I/O bandwidth. The implementation provides compile-time selection between LZ4 and Snappy compression algorithms.

## Overview

- **Optional**: Compression is completely optional - BitBarrel works fine without it
- **Compile-time selection**: Choose your compression algorithm at build time
- **Selective compression**: Only values above a configurable threshold are compressed
- **Backward compatible**: Can read data files created without compression
- **Mixed algorithm support**: Future-proof design supports multiple algorithms in the same data file

## Supported Algorithms

### LZ4 (Recommended)
- **Speed**: ~500 MB/s compression, GB/s decompression
- **Ratio**: ~2.1:1 compression ratio (2.7:1 with high compression mode)
- **Features**: Multiple compression modes, excellent for medium-sized values (1KB-10KB)
- **Use case**: Best overall performance, ideal for most workloads

### Snappy
- **Speed**: ~250 MB/s compression, ~500 MB/s decompression
- **Ratio**: ~1.5-1.7:1 compression ratio
- **Features**: More robust error handling, stable bitstream format
- **Use case**: When data corruption resilience is more important than maximum compression

## Configuration

### Runtime Configuration
Compression can be controlled via configuration:

```yaml
storage:
  data_dir: "./data"
  compression:
    enabled: true          # Enable/disable compression
    threshold: 256          # Minimum size to compress (bytes)
    level: "default"        # Compression level: "fast", "default", "best"
```

### Compile-time Selection
Build with your preferred algorithm:

```bash
# Build with LZ4 compression
nim c -d:lz4Compression -d:release src/bitbarrel.nim

# Build with Snappy compression
nim c -d:snappyCompression -d:release src/bitbarrel.nim

# Build without compression (default)
nim c -d:release src/bitbarrel.nim
```

### Nimble Tasks
Use the provided nimble tasks:

```bash
# Build with LZ4
nimble buildLz4

# Build with Snappy
nimble buildSnappy

# Build without compression
nimble buildDefault
```

## Dependencies

Both compression libraries are automatically available as dependencies:

For LZ4 support:
- Install liblz4-dev: `apt-get install liblz4-dev` (Ubuntu/Debian)
- No additional nimble packages needed - included as dependency

For Snappy support:
- No additional packages needed - supersnappy is included as dependency

## Implementation Details

### Record Format
The record format has been extended to support compression:

```
[CRC32:4][timestamp:8][keyLen:4][key][valLen:4][flags:1][algorithm:1][value]
```

- **flags**: Bit 0 indicates compression (1 = compressed, 0 = uncompressed)
- **algorithm**: Algorithm ID (0 = none, 1 = LZ4, 2 = Snappy)
- **valLen**: Stores the *original* uncompressed size
- **value**: May be compressed or uncompressed

### Backward Compatibility
- Old format records (without flags/algorithm bytes) are read automatically
- Mixed formats can coexist in the same data file
- Future algorithm migration is supported via algorithm IDs

### Performance Considerations

#### When to Use Compression
- **Use**: Values > 256 bytes (default threshold)
- **Benefit**: Compressible text, JSON, logs, documents
- **Avoid**: Already compressed data (JPEG, MP3), very small values

#### LZ4 Performance
- Write overhead: +5-10ms for compression (amortized over large values)
- Space savings: 30-50% for compressible data
- I/O reduction: Significant for large values

## Best Practices

1. **Choose LZ4** for best overall performance
2. **Use Snappy** if robust error handling is critical
3. **Set threshold** appropriately for your data (256-1024 bytes typical)
4. **Test with real data** to measure actual compression ratios
5. **Monitor performance** - compression adds CPU overhead but saves I/O

## Migration

To enable compression on an existing BitBarrel deployment:

1. Build BitBarrel with compression support
2. Update configuration to enable compression
3. New writes will use compression automatically
4. Old records remain readable and are gradually compressed during compaction operations
5. No data migration is required

## Troubleshooting

### Compression Not Working
- Check that compression is enabled in config
- Verify threshold is appropriate for your data
- Values smaller than threshold won't be compressed

### Build Errors with LZ4
- Install liblz4-dev system package
- Check futhark is installed (`nimble install futhark`)

### Performance Issues
- Larger threshold reduces CPU overhead
- Use LZ4 for better performance
- Monitor compression ratios - inefficient compression wastes CPU

## API Reference

The compression API is available in `storage/compression.nim`:

```nim
# Check if compression is enabled
if compressionEnabled:
  # Compress data
  let compressed = compress(originalData)

  # Decompress data
  let decompressed = decompress(compressed, originalSize)

# Check if data should be compressed
if shouldCompress(data, threshold):
  # Compress if beneficial
  if isCompressionBeneficial(originalSize, compressedSize):
    # Use compressed data
```

## Testing

Run compression tests:

```bash
# Test without compression
nim c -r --path:src tests/test_compression.nim

# Test with LZ4
nim c -r --path:src  -d:lz4Compression tests/test_compression.nim

# Test with Snappy
nim c -r --path:src -d:snappyCompression tests/test_compression.nim
```