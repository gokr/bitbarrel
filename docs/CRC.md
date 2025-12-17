# CRC32 Validation in BitBarrel

BitBarrel uses CRC32 checksums to verify data integrity on reads. This document explains the rationale and configuration options.

## What CRC32 Protects Against

| Threat | Description | CRC32 Helps? |
|--------|-------------|--------------|
| **Partial writes** | Power loss mid-write leaves truncated/garbage data | Yes |
| **Silent data corruption** | Bit rot on aging storage media | Yes |
| **Application bugs** | Reading from wrong offset, wrong file, stale buffer | Yes |
| **Storage stack bugs** | Filesystem or driver bugs corrupting data | Yes |

## What Modern Systems Already Provide

| Layer | What It Protects | Limitations |
|-------|------------------|-------------|
| **SSD/HDD ECC** | Bit errors on media | Silent failures still happen; can't detect firmware bugs |
| **Filesystem journaling** (ext4, XFS) | Metadata consistency | Does NOT checksum data blocks |
| **ZFS/Btrfs checksums** | All data blocks | Full protection - CRC32 is redundant |
| **RAM ECC** | Memory bit flips | Not all systems have ECC RAM |

**Key insight**: Most common filesystems (ext4, XFS, NTFS, APFS) do **not** checksum data blocks. They only journal metadata to prevent filesystem corruption, not data corruption.

## When to Disable CRC Validation

Consider disabling (`validateCrc: false`) when:

1. **Using ZFS or Btrfs** - These filesystems already checksum every block
2. **Extreme read performance needs** - Every microsecond counts (rare for disk-bound workloads)
3. **Trusted environment** - Data integrity verified at another layer

## When to Keep CRC Enabled (Default)

Keep enabled (`validateCrc: true`) when:

1. **Using ext4, XFS, NTFS, or APFS** - No data checksums at filesystem level
2. **Long-term data storage** - Silent corruption accumulates over time
3. **Mission-critical data** - Defense in depth is valuable

## Performance Impact

CRC32 with hardware acceleration (SSE4.2/ARM CRC) achieves **~3 GB/s** throughput. For a disk-bound key-value store where SSD reads are 500 MB/s - 3 GB/s, CRC validation adds negligible overhead.

The bottleneck is always I/O, not checksumming.

## Configuration

```nim
var config = defaultBarrelConfig()
config.validateCrc = false  # Disable for ZFS users
let barrel = openBarrel("mydata", config)
```

Default: `validateCrc = true` (recommended for most deployments)

## Implementation Details

- CRC32 is computed over the encoded record (timestamp + key + value + flags)
- 4-byte CRC is stored before each record in the data file
- Validation occurs on every `get()` call when enabled
- Recovery also supports optional CRC validation (`RecoveryConfig.validateChecksums`)
