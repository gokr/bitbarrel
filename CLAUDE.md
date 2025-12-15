# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

BitBarrel is a high-performance Bitcask-style key-value storage engine written in Nim. It provides:
- Append-only log files with O(1) reads via in-memory hash index
- CRC32 data integrity verification
- Crash recovery with hint files for fast startup (40K+ keys/sec)
- Background merge/compaction with threading
- Configurable durability (immediate, buffered, batched, time-based sync modes)
- Write buffering and read-ahead caching

**Current Status**: Core implementation complete with advanced features - ready for production use.

## Build Commands

```bash
nimble install           # Install dependencies
nimble build             # Build the kvs binary
nimble test              # Run all tests (65 tests)
nimble clean             # Remove generated data files and binaries

# Specific test suites
nimble testStorage       # Storage layer tests
nimble testKeydir        # KeyDir index tests
nimble testIntegration   # Integration tests
nimble testRecovery      # Recovery system tests

# Demos
nimble demoBasic         # Basic CRUD operations
nimble demoSample        # Detailed key-value demo
nimble demoTuning        # Performance tuning demo

# Benchmarks
nimble bench             # Default benchmark
nimble benchQuick        # Quick benchmark (1K ops)
nimble benchComprehensive # Extended benchmark (100K ops)
nimble stress            # Stress testing
```

## Testing

Tests use Nim's `unittest` module. Located in `tests/`:

| Test File | Coverage |
|-----------|----------|
| `test_storage.nim` | Data file format, header, append/read |
| `test_record.nim` | Record encoding/decoding, CRC32, tombstones |
| `test_keydir.nim` | KeyDir operations, threading |
| `test_integration.nim` | GET/SET/DELETE workflow, persistence |
| `test_error_handling.nim` | Corruption detection, boundary conditions |
| `test_recovery.nim` | Recovery engine, checkpoints, hint files |
| `test_merge.nim` | Merge/compaction, background threading |
| `test_writebuffer.nim` | Write buffer sync modes |
| `test_readbuffer.nim` | Read buffering/caching |
| `test_hintfile.nim` | Hint file I/O |

Run individual tests directly: `nim c -r tests/test_storage.nim`

## Architecture

### Layered Design

```
┌─────────────────────────────────────────────┐
│  SimpleAPI (src/bitbarrel/simpleapi.nim)          │  High-level: open/get/set/delete
├─────────────────────────────────────────────┤
│  LowLevelAPI (src/bitbarrel/lowlevelapi.nim)      │  Direct storage access
├─────────────────────────────────────────────┤
│  Storage Engine (src/storage/)              │  Bitcask implementation
└─────────────────────────────────────────────┘
```

### Storage Engine Components

| Module | Purpose |
|--------|---------|
| `keydir.nim` | In-memory hash index (key → file position) |
| `datafile.nim` | Append-only file I/O with headers |
| `record.nim` | Binary record format: `[CRC32][timestamp][keyLen][key][valLen][value]` |
| `merge.nim` | Background compaction with priority scoring |
| `recovery.nim` | Crash recovery, KeyDir reconstruction |
| `hintfile.nim` | Fast recovery metadata (key positions only) |
| `writebuffer.nim` | Write batching with 4 sync modes |
| `checkpoint.nim` | KeyDir snapshots (full/incremental) |

### Bitcask Model

1. **Writes**: Append to active data file, update KeyDir in memory
2. **Reads**: KeyDir lookup (O(1)) → single disk seek + read
3. **Deletes**: Write tombstone record (empty value)
4. **Compaction**: Background merge eliminates tombstones and duplicates

## Project Structure

```
src/
├── kvs.nim              # Main library entry point
├── kvs/
│   ├── simpleapi.nim    # High-level API (SimpleBitBarrel)
│   ├── lowlevelapi.nim  # Low-level API
│   ├── config.nim       # Configuration types
│   ├── config_parser.nim # YAML/ENV config parsing
│   └── types.nim        # Core type definitions
├── storage/
│   ├── keydir.nim       # In-memory hash index
│   ├── datafile.nim     # Data file management
│   ├── record.nim       # Record serialization
│   ├── merge.nim        # Compaction engine
│   ├── recovery.nim     # Crash recovery
│   ├── writebuffer.nim  # Write buffering
│   ├── hintfile.nim     # Hint files
│   └── checkpoint.nim   # KeyDir checkpoints
└── cli/
    └── main.nim         # CLI interface
tests/                   # Test suite (14 files)
bench/                   # Benchmarks and stress tests
examples/                # Demo programs
```

## Nim Coding Guidelines

### Code Style and Conventions
- Use camelCase, not snake_case (avoid `_` in naming)
- Do not shadow the local `result` variable (Nim built-in)
- Doc comments: `##` below proc signature
- Prefer generics or object variants over methods and type inheritance
- Use `return expression` for early exits
- Prefer direct field access over getters/setters
- **NO `asyncdispatch`** - use threads or taskpools for concurrency
- Remove old code during refactoring
- Import full modules, not selected symbols
- Use `*` to export fields that should be publicly accessible
- When using fmt **ALWAYS** write it as `fmt("...")` not `fmt"..."` (escaped characters)

### Function and Return Style
- **Single-line functions**: Use direct expression without `result =` or `return`
- **Multi-line functions**: Use `result =` assignment and `return` for clarity
- **Early exits**: Use `return value` instead of `result = value; return`
- **Exception handlers**: Use `return expression` for error cases

### Comments and Documentation
- Do not add comments talking about how good something is
- Do not add comments that reflect what has changed (use git)
- Do not add unnecessary commentary or explain self-explanatory code

### Refactoring
- Remove old unused code during refactoring
- Delete deprecated methods, unused types, and obsolete code paths immediately
- Keep the codebase lean and focused

## Thread Safety

The BitBarrel uses threading for background operations (merge/compaction). Key patterns:

### Lock-Protected Data Structures
- **KeyDir**: Uses `Lock` for concurrent access to the hash index
- **DataFile**: Lock-protected file I/O operations
- **WriteBuffer**: Lock + condition variable for worker coordination

### GC Safety Pattern
For threaded code that accesses shared state, use `{.gcsafe.}` blocks:

```nim
proc someThreadedProc*() {.gcsafe.} =
  {.gcsafe.}:
    # Access to shared state that is actually thread-safe
    # but can't be proven so by the compiler
    withLock(keydir.lock):
      keydir.entries[key] = entry
```

Use `{.gcsafe.}:` blocks only when certain the code is actually thread-safe (e.g., lock-protected access).

### Merge Worker Threading
The merge system uses atomic flags for shutdown signaling and channels for coordination. See `src/storage/merge.nim` for the background worker pattern.

## Documentation Guidelines

### Writing Style
- Use neutral, factual language
- Avoid superlatives and hype words
- Describe features without marketing language
- Focus on implementation details and behavior

### Do's and Don'ts
- Do: "Fast recovery"
- Don't: "Ultra-fast recovery"
- Do: "Provides good performance"
- Don't: "Optimal performance", "Maximum performance"
- Do: "Buffer size 64KB-256KB (recommended)"
- Don't: "Optimal buffer size", "Perfect for X"

### Performance
- Use "~" for approximate values: "~250K ops/sec"
- Include measurement context implicitly or explicitly
- Use "fast" sparingly, only when justified
- Avoid "extremely", "incredibly", "amazingly"

### General Tone
- Professional but understated
- Technical, not promotional
- Helpful without exaggeration
- Clear and direct

## Tutorial

See [docs/TUTORIAL.md](docs/TUTORIAL.md) for comprehensive documentation on using BitBarrel, including:
- API usage examples
- Performance benchmarks
- Configuration options
- Best practices
- Troubleshooting guide
