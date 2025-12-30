# BitBarrel Documentation

Welcome to the BitBarrel documentation! BitBarrel is a high-performance Bitcask-style key-value storage engine written in Nim.

## Quick Start

New to BitBarrel? Start here:

- [Getting Started](GETTING_STARTED.md) - Set up and running in 5 minutes
- [User Tutorial](USER_GUIDE/tutorial.md) - Comprehensive usage guide
- [API Reference](USER_GUIDE/api-reference.md) - Complete API documentation
- [Comparing with Other Databases](COMPARISON.md) - BitBarrel vs Redis, PostgreSQL, MongoDB, RocksDB

## Documentation Structure

### User Documentation
For users who want to use BitBarrel in their applications:

- **[Getting Started](GETTING_STARTED.md)** - Quick setup and basic usage
- **[User Guide](USER_GUIDE/)**
  - [Tutorial](USER_GUIDE/tutorial.md) - Complete usage tutorial
  - [Configuration](USER_GUIDE/configuration.md) - All configuration options
  - API Documentation - Generated from code comments via `nim doc`

### Developer Documentation
For developers who want to contribute or understand internals:

- **[Developer Guide](DEVELOPER_GUIDE/)**
  - [Architecture](DEVELOPER_GUIDE/architecture.md) - System architecture and design
  - [Testing](DEVELOPER_GUIDE/testing.md) - Test suite and testing practices
  - [Performance](DEVELOPER_GUIDE/performance.md) - Benchmarking and optimization
  - [Memory Management](DEVELOPER_GUIDE/memory-management.md) - Nim memory patterns in BitBarrel

### Feature Documentation
Detailed documentation for specific BitBarrel features:

- **[Features](FEATURES/)**
  - [Compression](FEATURES/compression.md) - Data compression support
  - [Data Integrity](FEATURES/data-integrity.md) - CRC32 validation
  - [Networking](FEATURES/networking.md) - Network protocol and client
  - [Hint Files](FEATURES/hint-files.md) - Metadata files for fast recovery (40K+ keys/sec)
  - [Read-Ahead LRU Buffering](FEATURES/read-buffering.md) - Caching with LRU eviction

### Client Libraries and Tools
BitBarrel provides client libraries for multiple programming languages and a web admin console:

- **[Nim Client](../clients/nim/README.md)** - Full WebSocket protocol implementation
- **[Go Client](../clients/go/README.md)** - Full WebSocket protocol implementation
- **[Dart/Flutter Client](../clients/dart/README.md)** - Mobile + Web compatible client
- **[Python Client](../clients/python/README.md)** - Feature-complete WebSocket client
- **[Web Admin Console](../webadmin/README.md)** - Flutter-based web UI for database management

| Feature | Nim | Go | Dart/Flutter | Python | Web Admin |
|---------|-----|----|--------------|--------|-----------|
| WebSocket protocol | ✅ | ✅ | ✅ | ✅ | ✅ |
| CRUD operations | ✅ | ✅ | ✅ | ✅ | ✅ |
| Barrel management | ✅ | ✅ | ✅ | ✅ | ✅ |
| Barrel config ops | ✅ | ✅ | ✅ | ✅ | ✅ |
| Range queries | ✅ | ✅ | ✅ | ✅ | ✅ |
| Prefix queries | ✅ | ✅ | ✅ | ✅ | ✅ |
| Reference traversal | ✅ | ✅ | ✅ | ✅ | - |
| Cursor pagination | ✅ | ✅ | ✅ | ✅ | ✅ |
| JWT authentication | ✅ | - | - | - | ✅ |
| Context manager | ✅ | - | - | ✅ | - |
| Mobile support | - | - | ✅ | - | - |
| Web support | - | - | ✅ | - | ✅ |
| Visual UI | - | - | - | - | ✅ |
| JSON visualization | - | - | - | - | ✅ |


### Historical and Research
Background information and experimental features:

- **[Research](research/)**
  - [Bitcask Background](research/bitcask-background.md) - History and theory
  - [HugeBarrel Analysis](research/hugebarrel-analysis.md) - Critical review of HugeBarrel
  - [HugeCritBit Design](research/hugecritbit-design.md) - Design analysis
  - [Reference Model](research/REFERENCES.md) - Graph traversal with cycle detection
  - [References](research/references.md) - External references

## Choose Your Path

### I just want to use BitBarrel
1. [Getting Started](GETTING_STARTED.md)
2. [User Tutorial](USER_GUIDE/tutorial.md)
3. [Configuration](USER_GUIDE/configuration.md)
4. API Documentation - Run `nim doc src/bitbarrel.nim` to generate

### I want to understand how it works
1. [Architecture](DEVELOPER_GUIDE/architecture.md)
2. [Bitcask Background](research/bitcask-background.md)
3. [Performance](DEVELOPER_GUIDE/performance.md)

### I want to contribute
1. [Memory Management](DEVELOPER_GUIDE/memory-management.md) - Important for Nim development
2. [Testing](DEVELOPER_GUIDE/testing.md) - Test suite overview
3. [Architecture](DEVELOPER_GUIDE/architecture.md) - Code structure

### I need to tune performance
1. [Performance](DEVELOPER_GUIDE/performance.md)
2. [Configuration](USER_GUIDE/configuration.md) - Performance tuning section
3. [Features](FEATURES/) - Compression, networking options

## Key Concepts

BitBarrel implements the **Bitcask** storage model with these key concepts:

- **Append-only log files** - Fast sequential writes
- **In-memory hash index** - O(1) key lookups
- **CRC32 checksums** - Data integrity validation
- **Non-blocking compaction** - Writes continue during background compaction
- **Multiple index modes** - Hash, CritBit, HugeCritBit

### Index Modes

| Mode | Use Case | Features |
|------|----------|----------|
| `bmHash` | Simple key-value lookups | O(1) lookups, minimal memory |
| `bmCritBit` | Ordered data, range queries | Prefix search, range scans |
| `bmHugeCritBit` | Massive datasets | Two-tier storage, range queries |

## Performance Characteristics

Typical performance on ThinkPad Carbon X1 with SSD (release builds):

- **Writes**: ~9K-188K ops/sec (depends on sync mode: fsync to none)
- **Reads**: ~172K ops/sec (cache-friendly, in-memory index)
- **Recovery**: 68K+ keys/sec with hint files (14.6ms for 1,000 keys)
- **Mixed workload** (80% read): ~137K ops/sec combined
- **Storage**: Append-only, compacted in background

*Performance varies significantly based on sync mode, buffer configuration, and workload characteristics. See [benchmark guide](DEVELOPER_GUIDE/performance.md) for detailed results.*

## Contributing to Documentation

Documentation lives in the `docs/` directory:

```
docs/
├── GETTING_STARTED.md           # Quick start guide
├── README.md                    # This file
├── USER_GUIDE/                  # User documentation
├── DEVELOPER_GUIDE/             # Developer documentation
├── FEATURES/                    # Feature-specific docs
└── research/                    # Historical/experimental
```

### Style Guidelines

- Use clear, concise language
- Include code examples for all major concepts
- Cross-reference related topics
- Keep technical accuracy - verify against implementation

### Building Documentation

Documentation is plain Markdown. No special build process required.

## External Resources

- [BitBarrel GitHub Repository](https://github.com/your-repo/bitbarrel)
- [Nim Programming Language](https://nim-lang.org/)
- [Original Bitcask Paper](https://riak.com/assets/bitcask-intro.pdf)
- [CLAUDE.md](../CLAUDE.md) - Development guidelines for the project

## Need Help?

- Check the [FAQ](USER_GUIDE/tutorial.md#faq) in the tutorial
- Look at demos in the `demos/` directory
- Run tests: `nimble test`
- Review architecture: [DEVELOPER_GUIDE/architecture.md](DEVELOPER_GUIDE/architecture.md)