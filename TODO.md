# BitBarrel Development Priorities

## Current Status

BitBarrel is a production-ready Bitcask-style key-value storage engine with comprehensive features:
- Three indexing modes (bmHash, bmCritBit, bmHugeCritBit)
- Full network protocol with WebSocket and REST APIs
- Pub/Sub messaging system with history storage
- Multiple client libraries (Nim, Go, Python, Dart, TypeScript)
- Web admin console
- Comprehensive test suite

Recent fixes have addressed protocol mismatches and pub/sub storage initialization issues.

## Priority Levels

### Critical (Immediate - Blocking Issues)
1. **Client library consistency verification**
   - Ensure all clients handle `LIST_SUBSCRIBERS` protocol correctly (topic in `value` field)
   - Verify pub/sub storage configuration works across all clients
   - Test recent protocol fixes with all client libraries

2. **Documentation consistency**
   - Ensure all documentation reflects recent fixes (protocol, pub/sub storage)
   - Update CLAUDE.md testing section to match actual nimble tasks
   - Verify bmHugeCritBit documentation accuracy

### High Priority (Next Release)
3. **ORC crash prevention patterns documentation**
   - Document `{.acyclic.}` usage patterns in developer guide
   - Add closure elimination examples from compact.nim
   - Update network architecture documentation with thread safety patterns

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

## Recently Completed (Verification Needed)

The following items were recently fixed and need verification:

### Protocol Fixes ✅
- **LIST_SUBSCRIBERS command**: Fixed protocol mismatch where topic should be in `value` field, not `key` field
- **Verification**: All clients should be tested with updated protocol documentation

### Pub/Sub Storage Fixes ✅
- **History store connection**: Fixed history store not being connected to pub/sub manager
- **Config mismatch**: Fixed `setSharedBarrelConfig()` updating both `defaultStrategy` and `defaultTopicConfig.strategy`
- **bmCritBit initialization**: Fixed shared barrel backend requiring bmCritBit mode from start
- **Verification**: Test pub/sub history storage with persistence enabled

### Client Library Fixes ✅
- **Python client**: Fixed handling of interleaved Pub/Sub events
- **Nim client**: Fixed request/response handling and batching
- **All clients**: Added configurable timeout to network client `sendAndWait`
- **Verification**: Run client integration tests

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

Last updated: 2026-01-18 (based on git history through commit ab48639)