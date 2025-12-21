# Package

version       = "0.3.0"
author        = "Göran Krampe"
description   = "High-Performance Bitcask-style Key/Value Store"
license       = "MIT"
srcDir        = "src"
bin           = @["bitbarrel"]

# Dependencies

requires "nim >= 2.2.6"
requires "crunchy >= 0.1.0"
requires "yaml >= 2.1.0"
requires "supersnappy"      # For optional Snappy support
requires "https://github.com/gokr/lz4wrapper" # For optional LZ4 support
requires "https://github.com/gokr/mummy"      # WebSocket/HTTP server

# Task for testing

task test, "Run all tests":
  exec "nim c -r tests/test_storage.nim"
  exec "nim c -r tests/test_keydir.nim"
  exec "nim c -r tests/test_integration.nim"
  exec "nim c -r tests/test_record.nim"
  exec "nim c -r tests/test_compression.nim"
  exec "nim c -r tests/test_error_handling.nim"
  exec "nim c -r tests/test_recovery.nim"

task testAll, "Run complete test suite (all test files)":
  exec "nim c -r tests/test_storage.nim"
  exec "nim c -r tests/test_keydir.nim"
  exec "nim c -r tests/test_integration.nim"
  exec "nim c -r tests/test_record.nim"
  exec "nim c -r tests/test_compression.nim"
  exec "nim c -r tests/test_error_handling.nim"
  exec "nim c -r tests/test_recovery.nim"
  exec "nim c -r tests/test_config.nim"
  exec "nim c -r tests/test_barrel.nim"
  exec "nim c -r tests/test_hintfile.nim"
  exec "nim c -r tests/test_compact.nim"
  exec "nim c -r tests/test_writebuffer.nim"
  exec "nim c -r tests/test_readbuffer.nim"
  exec "nim c -r tests/test_ttl.nim"
  exec "nim c -r tests/test_refs.nim"
  exec "nim c -r tests/test_protocol.nim"
  exec "nim c -r tests/test_session.nim"
  exec "nim c -r tests/test_client.nim"
  exec "nim c -r tests/test_server.nim"
  exec "nim c -r tests/test_simple_memory.nim"
  exec "nim c -r tests/test_crash_recovery.nim"
  exec "nim c -r tests/test_filesystem_stress.nim"
  exec "nim c -r tests/test_memory_pressure.nim"
  exec "nim c -r tests/test_concurrent_access.nim"
  echo "✓ All tests completed successfully!"

task testStorage, "Run storage tests":
  exec "nim c -r tests/test_storage.nim"

task testKeydir, "Run KeyDir tests":
  exec "nim c -r tests/test_keydir.nim"

task testIntegration, "Run integration tests":
  exec "nim c -r tests/test_integration.nim"

task testRecovery, "Run recovery tests":
  exec "nim c -r tests/test_recovery.nim"

# Tasks for running demos

task demoBasic, "Run basic CRUD demo":
  exec "nim c -r --path:src examples/basic_demo.nim"

task demoSample, "Run detailed demo":
  exec "nim c -r --path:src examples/simple_kv_demo.nim"

task demoTuning, "Run performance tuning demo":
  exec "nim c -r --path:src examples/performance_tuning_demo.nim"

task demoCompression, "Run compression demo":
  exec "nim c -r --path:src examples/compression_demo.nim"

task demoBarrelModes, "Run barrel modes demo":
  exec "nim c -r --path:src examples/barrel_modes_demo.nim"

task demoBuffer, "Run buffer performance demo":
  exec "nim c -r --path:src examples/buffer_demo.nim"

task demoConfig, "Run configuration demo":
  exec "nim c -r --path:src examples/configuration_demo.nim"

task demoContentGraph, "Run content graph traversal demo":
  exec "nim c -r --path:src examples/content_graph_demo.nim"

task demoDemo, "Run basic operations demo":
  exec "nim c -r --path:src examples/demo.nim"

task demoOrgChart, "Run organization chart demo":
  exec "nim c -r --path:src examples/org_chart_demo.nim"

task demoPerfSimple, "Run simple performance demo":
  exec "nim c -r --path:src examples/performance_tuning_simple.nim"

task demoSocialGraph, "Run social graph traversal demo":
  exec "nim c -r --path:src examples/social_graph_demo.nim"

task checkDemos, "Compile all examples (verification check) - exits on first error":
  exec "nim c --verbosity:0 --path:src examples/basic_demo.nim"
  exec "nim c --verbosity:0 --path:src examples/simple_kv_demo.nim"
  exec "nim c --verbosity:0 --path:src examples/performance_tuning_demo.nim"
  exec "nim c --verbosity:0 --path:src examples/compression_demo.nim"
  exec "nim c --verbosity:0 --path:src examples/barrel_modes_demo.nim"
  exec "nim c --verbosity:0 --path:src examples/buffer_demo.nim"
  exec "nim c --verbosity:0 --path:src examples/configuration_demo.nim"
  exec "nim c --verbosity:0 --path:src examples/content_graph_demo.nim"
  exec "nim c --verbosity:0 --path:src examples/demo.nim"
  exec "nim c --verbosity:0 --path:src examples/org_chart_demo.nim"
  exec "nim c --verbosity:0 --path:src examples/performance_tuning_simple.nim"
  exec "nim c --verbosity:0 --path:src examples/social_graph_demo.nim"
  echo "✓ All examples compiled successfully!"

# Task for benchmarking

task bench, "Run comprehensive benchmark suite":
  exec "nim c -d:release -r --path:src bench/unified_benchmark.nim"

task benchQuick, "Run quick benchmark (1000 ops)":
  exec "nim c -d:release -r --path:src bench/unified_benchmark.nim quick"

task benchComprehensive, "Run comprehensive benchmark (100K ops)":
  exec "nim c -d:release -r --path:src bench/unified_benchmark.nim comprehensive"

task benchCrunchy, "Run performance benchmark with crunchy CRC32":
  exec "nim c -d:release -d:useCrunchy -r bench/simple_bench.nim"

# Task for stress testing

task stress, "Run stress tests":
  exec "nim c -d:release -r bench/stress_test.nim"

# Tasks for network server and client

task server, "Build and run BitBarrel network server":
  exec "nim c -d:release --mm:orc --threads:on -o:bitbarrel_server src/network/server_main.nim && ./bitbarrel_server"

task client, "Build BitBarrel network client library":
  exec "nim c -d:release --mm:orc --threads:on -o:bitbarrel_client src/network/client.nim"

task testNetwork, "Run network integration tests":
  exec "nim c -r tests/test_client.nim"
  exec "nim c -r tests/test_server.nim"

task benchNetwork, "Run network benchmark (1000 ops)":
  exec "nim c -d:release --mm:orc --threads:on -r --path:src bench/network_bench.nim quick"

task benchNetworkComprehensive, "Run comprehensive network benchmark (100K ops, 10 clients)":
  exec "nim c -d:release --mm:orc --threads:on -r --path:src bench/network_bench.nim comprehensive"

# Quick test - runs all tests

task quickTest, "Run quick test suite":
  exec "nim c -r tests/test_storage.nim"
  exec "nim c -r tests/test_keydir.nim"
  exec "nim c -r tests/test_integration.nim"
  exec "nim c -r tests/test_record.nim"
  exec "nim c -r tests/test_compression.nim"
  exec "nim c -r tests/test_error_handling.nim"
  exec "nim c -r tests/test_recovery.nim"

# Full test - tests + demos + benchmarks

task fullTest, "Run full test suite":
  echo "=== Running Tests ==="
  exec "nim c -r tests/test_storage.nim"
  exec "nim c -r tests/test_keydir.nim"
  exec "nim c -r tests/test_integration.nim"
  exec "nim c -r tests/test_record.nim"
  exec "nim c -r tests/test_compression.nim"
  exec "nim c -r tests/test_error_handling.nim"
  exec "nim c -r tests/test_recovery.nim"
  echo ""
  echo "=== Running Demos ==="
  exec "nim c -r examples/basic_demo.nim"
  echo ""
  echo "=== All Tests Completed Successfully ==="

# Clean task - remove generated data files only (not source code)

task clean, "Clean up generated data files":
  exec "rm -f test_*.data"
  exec "rm -f tests/*.data"
  exec "rm -f bench/*.data"
  exec "rm -f examples/*.data"
  # Remove compiled test binaries
  exec "rm -f tests/test_storage tests/test_keydir tests/test_integration tests/test_recovery"
  exec "rm -f bench/simple_bench bench/stress_test"
  exec "rm -f examples/basic_demo examples/simple_kv_demo"
  echo "Cleaned up generated data files and binaries"

# Build with compression support

task buildLz4, "Build with LZ4 compression support":
  echo "Building BitBarrel with LZ4 compression..."
  exec "nim c -d:lz4Compression -d:release src/bitbarrel.nim"

task buildSnappy, "Build with Snappy compression support":
  echo "Building BitBarrel with Snappy compression..."
  exec "nim c -d:snappyCompression -d:release src/bitbarrel.nim"

task buildDefault, "Build without compression (default)":
  echo "Building BitBarrel without compression..."
  exec "nim c -d:release src/bitbarrel.nim"