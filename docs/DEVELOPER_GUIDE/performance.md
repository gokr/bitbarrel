# BitBarrel Benchmark Guide

## Overview

The BitBarrel project now has two ways to run benchmarks:

## Current Benchmark Results (ThinkPad Carbon X1 with SSD)

Recent benchmark results from release builds:

### Write Performance
- **None sync**: ~188K ops/sec (buffered, fastest)
- **Sync**: ~186K ops/sec (OS-level durability)
- **Fsync**: ~9.1K ops/sec (disk-level durability)

### Read Performance
- **Sequential reads**: ~172K ops/sec
- **Random reads**: Similar via in-memory index

### Mixed Workload (80% read / 20% write)
- **Overall throughput**: ~137K ops/sec
- **Average latency**: ~0.007 ms

### Recovery Performance
- **With hint files**: 68,694 keys/sec (14.6ms for 1,000 keys)
- **Without hint files**: Full data file scan required

### Buffer Size Impact
- **4KB buffer**: Best performance (~197K ops/sec)
- **64KB-256KB**: Good performance range
- **1MB buffer**: Diminishing returns

*Note: Performance varies based on hardware, sync mode, and workload.*

## Quick Reference

### Running Benchmarks

```bash
# Main benchmark suite (10K ops, standard profile)
nimble bench

# Quick tests (1K ops)
nimble benchQuick

# Comprehensive (100K ops)
nimble benchComprehensive

# Stress test
nimble stress
```

## Individual Benchmarks

```bash
# Legacy simple benchmark (1000 ops)
nim c -d:release -r --path:src bench/simple_bench.nim 1000

# With crunchy CRC32
nim c -d:release -d:useCrunchy -r bench/simple_bench.nim 1000

# Stress test
nim c -d:release -r bench/stress_test.nim
```

## Nimble Tasks

| Task | Command | What it does |
|------|----------|-----------|

### Tests
- `nimble test` - Run all 25 tests
- `nimble test-storage` - Storage module tests
- `nimble test-keydir` - KeyDir tests
- `nimble test-recovery` - Recovery tests
- `nimble testNetwork` - Network protocol tests

### Demos
- `nimble demoBasic` - Basic CRUD example
- `nimble demoSample` - Detailed demo
- `nimble demoTuning` - Performance tuning demo

### Benchmarks
- `nimble bench` - Main benchmark suite
- `nimble benchQuick` - Quick benchmark (1K ops)
- `nimble benchComprehensive` - Full benchmark (100K ops)
- `nimble benchStress` - System stress tests
- `nimble benchNetwork` - Network benchmark (1K ops)
- `nimble benchNetworkComprehensive` - Network benchmark (100K ops, 10 clients)

### Compression Builds
- `nimble buildDefault` - Build without compression
- `nimble buildLz4` - Build with LZ4 compression
- `nimble buildSnappy` - Build with Snappy compression

### Configurations Tested

- **Sync Modes**: None, Sync, Fsync
- **Buffer Sizes**: 4KB, 64KB, 256KB, 1MB
- **Data Sizes**: 1K, 10K, 100K records
- **Key/Value Sizes**: Small, medium, large

## Performance Tuning

The `examples/performance_tuning_demo.nim` demonstrates how to:
- Switch between sync modes (fastest vs safest)
- Adjust buffer sizes
- Calculate performance improvements

## Recommendations

1. **For production**: Use `Fsync` for durability
2. **For speed**: Use `None` with 4KB buffer (gave best results in benchmarks)
3. **For balance**: Use `Sync` with moderate buffers (4KB-256KB)
4. **For stress**: Test with `nimble stress`

## See Also
- `nimble bench --help` - Shows all available commands
- `examples/performance_tuning_demo.nim` - Performance tuning examples
- `bench/results_baseline.txt` - Baseline performance results
- **Current benchmarks**: See "Current Benchmark Results" section above for latest numbers

## File Structure

For current project structure, see the repository root. Key directories:
- `src/` - Source code
- `tests/` - Test suite (25 test files)
- `bench/` - Benchmark suite
- `examples/` - Demo programs
- `docs/` - Documentation (see `docs/TUTORIAL.md` for usage guide)

**Note:** This file section is outdated. See repository for current structure.

```
kvs/
├── src/bitbarrel/
│   ├── types.nim
│   ├── config.nim
│   ├── barrel.nim
│   ├── lowlevelapi.nim
│   └── storage/
│       ├── datafile.nim
│       ├── keydir.nim
│       ├── record.nim
│       ├── hintfile.nim
│       ├── writebuffer.nim
│       └── readbuffer.nim
│       └── recovery.nim
│       ├── checkpoint.nim
│       └── merge.nim
│   └── kvs.nim
│   └── utils/
│       ├── demo_output.nim
│       ├── performance_timer.nim
│       └── data_generator.nim
├── examples/
│   ├── basic_demo.nim
│   ├── simple_kv_demo.nim
│   └── performance_tuning_demo.nim
│   └── buffer_demo.nim
│   └── buffer_example.nim
│   └── README.md
│   └── utils/
│       demo_output.nim
│       performance_timer.nim
│       data_generator.nim
├── bench/
│   ├── simple_bench.nim
│   ├── stress_test.nim
│   ├── unified_benchmark.nim
│   └── results/
│   │   ├── *.data
│   │   └── *.txt
│   └── └── stats.json
├── tests/
│   ├── test_storage.nim
│   ├── test_keydir.nim
│   ├── test_integration.nim
│   ├── test_record.nim
│   ├── test_error_handling.nim
│   ├── test_recovery.nim
│   ├── test_writebuffer.nim
│   ├── test_readbuffer.nim
│   └── test_hintfile.nim
│   └── test_hintfile_recovery.nim
│   └── test_merge.nim
│   └── test_readbuffer.nim
│
├── docs/
│   ├── TUTORIAL.md
│   └── PLAN.md
│   └── PHASE3_SUMMARY.md
└── [...]
```

## Next Steps

1. **Run benchmarks** to see performance with your hardware
2. **Configure** based on your use case
3. **Monitor** using the performance_tuning_demo
4. **Scale** by adjusting configurations in your application code