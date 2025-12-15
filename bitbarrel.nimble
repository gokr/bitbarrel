# Package

version       = "0.1.0"
author        = "Göran Krampe"
description   = "High-Performance Bitcask-style Key/Value Store"
license       = "MIT"
srcDir        = "src"
bin           = @["bitbarrel"]

# Dependencies

requires "nim >= 2.2.6"
requires "crunchy >= 0.1.0"
requires "yaml >= 2.1.0"

# Task for testing

task test, "Run all tests":
  exec "nim c -r tests/test_storage.nim"
  exec "nim c -r tests/test_keydir.nim"
  exec "nim c -r tests/test_integration.nim"
  exec "nim c -r tests/test_record.nim"
  exec "nim c -r tests/test_error_handling.nim"
  exec "nim c -r tests/test_recovery.nim"

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
  exec "nim c -r examples/basic_demo.nim"

task demoSample, "Run detailed demo":
  exec "nim c -r examples/simple_kv_demo.nim"

task demoTuning, "Run performance tuning demo":
  exec "nim c -r examples/performance_tuning_demo.nim"

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

# Task for building server

task server, "Build KVS server":
  echo "Server implementation coming in Phase 2"
  # exec "nim c -d:release src/server.nim"

# Task for building client

task client, "Build KVS client":
  echo "Client implementation coming in Phase 2"
  # exec "nim c -d:release src/client.nim"

# Quick test - runs all tests

task quickTest, "Run quick test suite":
  exec "nim c -r tests/test_storage.nim"
  exec "nim c -r tests/test_keydir.nim"
  exec "nim c -r tests/test_integration.nim"
  exec "nim c -r tests/test_record.nim"
  exec "nim c -r tests/test_error_handling.nim"
  exec "nim c -r tests/test_recovery.nim"

# Full test - tests + demos + benchmarks

task fullTest, "Run full test suite":
  echo "=== Running Tests ==="
  exec "nim c -r tests/test_storage.nim"
  exec "nim c -r tests/test_keydir.nim"
  exec "nim c -r tests/test_integration.nim"
  exec "nim c -r tests/test_record.nim"
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