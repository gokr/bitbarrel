# BitBarrel Test Suite

This directory contains comprehensive tests for the BitBarrel key-value storage engine.

## Running Tests

### All Tests
```bash
nimble test              # Run all tests
```

### Specific Test Categories
```bash
nimble testUnit          # Unit tests (storage, keydir, record, compression)
nimble testIntegration   # Integration tests (writebuffer, hints, recovery)
nimble testAPI           # API tests (barrel, ttl, range, refs, merge)
nimble testSystem        # System tests (concurrent, crash, memory, filesystem)
nimble testNetwork       # Network tests (WebSocket, REST, protocol)
nimble testError         # Error handling tests
nimble testHugeBarrel    # HugeBarrel feature tests
nimble testStorage       # Storage layer tests only
nimble testKeydir        # KeyDir tests only
nimble testRecovery      # Recovery system tests only
```

### Individual Test Files
```bash
nim c -r tests/test_record.nim      # Record module tests
nim c -r tests/test_keydir.nim      # KeyDir tests
nim c -r tests/test_recovery.nim    # Recovery system tests
# ... etc
```

## Test Organization

Tests are organized into several categories:

### 1. Unit Tests
Low-level component tests that verify individual modules:
- `test_record.nim` - Record encoding/decoding, CRC32 validation
- `test_keydir.nim` - In-memory hash index operations
- `test_datafile.nim` - Data file I/O operations
- `test_crc32.nim` - CRC32 checksum implementation
- `test_compression.nim` - Data compression/decompression

### 2. Integration Tests
Component interaction and workflow tests:
- `test_integration.nim` - DataFile + KeyDir integration
- `test_hintfile.nim` - Hint file basic I/O
- `test_recovery.nim` - Recovery system (includes hint file integration)
- `test_writebuffer.nim` - Write buffering (standard + simple)
- `test_readbuffer.nim` - Read buffering and caching
- `test_compact.nim` - Compaction system

### 3. API Tests
High-level Barrel API tests:
- `test_barrel.nim` - Main Barrel API (CRUD, configurations)
- `test_ttl.nim` - Time-to-live expiration
- `test_refs.nim` - Reference counting
- `test_rangekeydir.nim` - Range-based index
- `test_range_management.nim` - Range query operations
- `test_merge.nim` - Data merging operations

### 4. System Tests
Full system behavior and edge cases:
- `test_filesystem_stress.nim` - Filesystem errors, permissions, disk full
- `test_concurrent_access.nim` - Multi-threaded access patterns
- `test_crash_recovery.nim` - Crash scenarios and recovery
- `test_memory_pressure.nim` - Memory limits, leaks, fragmentation

### 5. Network Tests
Client-server communication:
- `test_protocol.nim` - Binary protocol encoding/decoding
- `test_session.nim` - Session and barrel registry
- `test_client.nim` - WebSocket client operations
- `test_server.nim` - REST API and WebSocket server

### 6. Error Handling Tests
- `test_error_handling.nim` - Corruption detection, boundary conditions

## Test Utilities

Common utilities are provided in `testutils.nim`:

### Directory Management
```nim
withTestDir("my_test"):
  # Test directory is created and automatically cleaned up
  let path = testDir / "test.data"
  # ... run test
```

### Record Creation
```nim
let rec = testRecord("key", "value")  # With current timestamp
let rec = testRecord("key", "value", 123456789)  # With specific timestamp
let tomb = tombstoneRecord("deleted_key")
let large = largeRecord(1000, 10000)  # 1KB key, 10KB value
```

### Data Builders
```nim
let data = buildTestData(100, "prefix")  # 100 records with "prefix_0", "prefix_1", etc.
let overlapData = buildTestDataWithOverlap(100, 10, "shared")  # 100 + 10 with overlaps
```

### File Corruption
```nim
writeCorruptFile(path, "corrupt data")
corruptFileAt(path, 100, char(0xFF))  # Corrupt byte at position 100
truncateFileAt(path, 500)  # Truncate to 500 bytes
```

### Test Vectors
```nim
# CRC32 test vectors
for (input, expected) in crc32TestVectors:
  check crc32(input) == expected

# Size parsing test vectors
for (input, expected) in sizeStringTestVectors:
  check parseSizeString(input) == expected
```

## Coverage

The test suite provides comprehensive coverage:

- ✅ **Functional correctness** - All core operations tested
- ✅ **Protocol compliance** - Binary protocol, WebSocket RFC 6455
- ✅ **Concurrent access** - Multi-threaded writes, read/write locking
- ✅ **Crash recovery** - Process killed mid-operation, partial writes
- ✅ **File corruption** - CRC validation, partial records
- ✅ **Filesystem errors** - Permission denied, disk full, invalid paths
- ✅ **Memory management** - Large datasets, memory leaks
- ✅ **Network resilience** - Connection reset, fragmentation, timeouts
- ✅ **Edge cases** - Boundary conditions, empty databases, tombstones

## Performance Tests

Benchmarks are in the `bench/` directory:
```bash
nimble bench              # Default benchmark
nimble benchQuick         # Quick benchmark (1K ops)
nimble benchComprehensive # Extended benchmark (100K ops)
nimble stress             # Stress testing
```

## Writing New Tests

### Use Test Utilities
Always use `testutils.nim` helpers for consistency:
```nim
import testutils

suite "My Feature Tests":
  test "Test case":
    withTestDir("my_feature"):
      # Test implementation
      check condition == true
```

### Test Naming
- Use descriptive test names: `test "recovers from partial write"` not `test "test1"`
- Group related tests in a suite
- Use `setup` and `teardown` for common initialization

### Assertions
Use `unittest` assertions:
```nim
check value == expected  # Generic assertion
expect SomeError:        # Expect exception
  procThatShouldFail()
```

### Cleanup
Always use `withTestDir` or `defer` for cleanup:
```nim
withTestDir("test_name"):
  # Test runs here
  # Directory automatically cleaned up
```

## Continuous Integration

Tests are designed to run in CI environments:
- No external dependencies (uses `/tmp` for test data)
- Short execution time (< 30 seconds for full suite)
- Platform-independent (Windows, Linux, macOS)
- Deterministic (no flaky time-based tests)

## Maintenance

When adding new features:
1. Add unit tests for the new component
2. Add integration tests for component interaction
3. Add edge case tests (error conditions, corner cases)
4. Update this README if adding new test categories

When fixing bugs:
1. Add a test that reproduces the bug
2. Fix the bug
3. Verify the test passes
4. Keep the test in the suite to prevent regression