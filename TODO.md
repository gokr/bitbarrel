# BitBarrel Development Priorities

## Current Status

BitBarrel is a production-ready Bitcask-style key-value storage engine with comprehensive features:
- Three indexing modes (bmHash, bmCritBit, bmHugeCritBit)
- Full network protocol with WebSocket and REST APIs
- Pub/Sub messaging system with history storage
- Multiple client libraries (Nim, Go, Python, Dart, TypeScript, C, Zig)
- Web admin console
- Comprehensive test suite

Recent fixes have addressed protocol mismatches and pub/sub storage initialization issues.

## Priority Levels

### Critical (Immediate - Blocking Issues)
1. **Client library consistency verification** ✅ COMPLETED
   - ✅ Ensure all clients handle `LIST_SUBSCRIBERS` protocol correctly (topic in `value` field)
   - ✅ Verify pub/sub storage configuration works across all clients
   - ✅ Test recent protocol fixes with all client libraries

2. **Documentation consistency** ✅ COMPLETED
   - ✅ Ensure all documentation reflects recent fixes (protocol, pub/sub storage)
   - ✅ Update CLAUDE.md testing section to match actual nimble tasks
   - ✅ Verify bmHugeCritBit documentation accuracy

### High Priority (Next Release)
3. **ORC crash prevention patterns documentation** ✅ COMPLETED
   - ✅ Document `{.acyclic.}` usage patterns in developer guide
   - ✅ Add closure elimination examples from compact.nim
   - ✅ Update network architecture documentation with thread safety patterns

4. **Testing framework improvements**
   - Add missing test commands to documentation
   - Verify test directory structure documentation accuracy
   - Ensure all test commands work as documented

5. **Pub/Sub storage backend validation**
   - Test hybrid storage configuration patterns
   - Verify bmCritBit mode requirement for shared barrel storage
   - Test history storage with multiple concurrent topics

### Medium Priority (Feature Enhancements)
6. **HugeBarrel (bmHugeCritBit) production readiness**
   - Complete coordinated compaction implementation
   - Improve documentation for separate API (`openHugeBarrel()`)
   - Add comprehensive tests for massive dataset scenarios

7. **Client library enhancements**
   - Connection pooling implementation
   - Request batching optimization
   - Improved error handling and retry logic

8. **Performance optimization**
   - Benchmark recent fixes impact on performance
   - Optimize pub/sub storage for high-throughput scenarios
   - Profile network protocol overhead

### Low Priority (Future Roadmap)
9. **Replication system**
   - Master-replica architecture design
   - Asynchronous replication implementation
   - Failover and promotion mechanisms

10. **Advanced query features**
    - Secondary indexes implementation
    - Simple query DSL for filtering
    - Aggregation functions

11. **Monitoring and observability**
    - Enhanced Prometheus metrics
    - Structured logging improvements
    - Health check endpoints

## Recently Completed (✅ VERIFIED)

### Network Protocol v1.1 ✅ VERIFIED
- **Binary Handshake**: Server sends versionMajor, versionMinor, serverId (UUID), and pluginCount after connection
- **Per-Key TTL**: SET command supports optional 4-byte TTL field via rfHasTtl flag
- **Key Watch Commands**: WATCH_KEY (0x60) and UNWATCH_KEY (0x61) for pattern-based key change subscriptions
- **Request Pipelining**: Client-side batching to reduce network round-trip latency
- **Protocol Documentation**: PROTOCOL.md fully updated with v1.1 specification
- **Status**: All v1.1 features implemented and documented

### Protocol Fixes ✅ VERIFIED
- **LIST_SUBSCRIBERS command**: Fixed protocol mismatch where topic should be in `value` field, not `key` field
- **Status**: All clients updated and tested (Go, Python, TypeScript, Dart, Nim)
- **Commits**: ab48639 (server), 4df0b76 (Go/Python/TS), f3cf218 (Dart)
- **Verification**: All client tests pass, protocol documentation updated

### Pub/Sub Storage Fixes ✅ VERIFIED
- **History store connection**: Fixed history store not being connected to pub/sub manager
- **Config mismatch**: Fixed `setSharedBarrelConfig()` updating both `defaultStrategy` and `defaultTopicConfig.strategy`
- **bmCritBit initialization**: Fixed shared barrel backend requiring bmCritBit mode from start
- **Status**: Tested with all client libraries, working correctly
- **Commits**: 40cdacf (config), b22b448 (bmCritBit), f14aad6 (history store)
- **Verification**: History tests pass in all client libraries

### Client Library Improvements ✅ VERIFIED
- **Python client**: Reduced test time from 20s to 2s (websocket timeout optimization)
- **Go client**: Added comprehensive pubsub tests (15 tests vs 6 before, now at parity)
- **All clients**: Protocol fixes applied and verified
- **Status**: All client libraries at parity for pubsub features
- **Commits**: 9b0bda3 (Go tests), f11ed08 (Python fixes)
- **Verification**: `nimble testClients` passes all tests

## Known Issues Requiring Attention

### ORC Garbage Collector Crashes
- **Status**: Mitigated with `{.acyclic.}` patterns and closure elimination
- **Affected**: Threaded code with cross-thread references
- **Action**: Document patterns and ensure all threaded code follows best practices

### bmHugeCritBit Implementation Status
- **Status**: Partially implemented with separate API (`openHugeBarrel()`)
- **Limitation**: Not accessible via standard `openBarrel()` API
- **Action**: Clarify documentation and consider API unification

### Testing Framework
- **Issue**: Documentation shows `testAll` command that doesn't exist
- **Action**: Update documentation to reflect actual nimble test tasks
- **Verification**: Ensure all test categories are documented

## Development Guidelines

### Code Quality
- Remove compiler warnings (unused imports, variables)
- Follow Nim coding conventions (camelCase, no shadowing of `result`)
- Use `{.acyclic.}` for types involved in cross-thread references
- Eliminate closures in threaded code, use raw pointers instead

### Documentation
- Update documentation after each significant change
- Ensure consistency between CLAUDE.md and other documentation
- Include code examples for public APIs
- Document protocol changes and breaking changes

### Testing
- Run tests after each change (`nimble test`)
- Verify client library tests pass (`nimble testClients`)
- Test network protocol with all clients
- Run benchmarks to verify performance impact

## Contribution Areas

Priority areas for community contributions:
1. **Client libraries**: Additional language bindings, performance improvements
2. **Documentation**: Tutorials, examples, API documentation
3. **Testing**: New test cases, property-based testing, stress tests
4. **Performance**: Profiling, optimization, benchmarking

## Getting Started for Developers

See [CLAUDE.md](CLAUDE.md) for detailed project instructions including:
- Build commands and dependencies
- Testing framework usage
- Architecture and code patterns
- Documentation guidelines

For user documentation:
- [GETTING_STARTED.md](docs/GETTING_STARTED.md) - Quick start guide
- [USER_GUIDE/tutorial.md](docs/USER_GUIDE/tutorial.md) - Comprehensive tutorial
- [PROTOCOL.md](docs/PROTOCOL.md) - Network protocol specification

Last updated: 2026-01-19 (verified through commit 9b0bda3, v1.1 protocol documented)