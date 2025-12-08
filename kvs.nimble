# Package

version       = "0.1.0"
author        = "Göran Krampe"
description   = "High-Performance Bitcask Key/Value Store"
license       = "MIT"
srcDir        = "src"
bin           = @["kvs"]

# Dependencies

requires "nim >= 2.2.6"

# Task for testing

task test, "Run all tests":
  exec "nim c -r tests/test_storage.nim"
  exec "nim c -r tests/test_keydir.nim"
  exec "nim c -r tests/test_integration.nim"
  exec "nim c -r tests/test_record.nim"
  exec "nim c -r tests/test_error_handling.nim"

task testStorage, "Run storage tests":
  exec "nim c -r tests/test_storage.nim"

task testKeydir, "Run KeyDir tests":
  exec "nim c -r tests/test_keydir.nim"

task testIntegration, "Run integration tests":
  exec "nim c -r tests/test_integration.nim"

# Tasks for running demos

task demoBasic, "Run basic CRUD demo":
  exec "nim c -r samples/basic_demo.nim"

task demoSample, "Run detailed demo":
  exec "nim c -r samples/simple_kv_demo.nim"

# Task for benchmarking

task bench, "Run performance benchmark":
  exec "nim c -d:release -r bench/simple_bench.nim"

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

# Full test - tests + demos + benchmarks

task fullTest, "Run full test suite":
  echo "=== Running Tests ==="
  exec "nim c -r tests/test_storage.nim"
  exec "nim c -r tests/test_keydir.nim"
  exec "nim c -r tests/test_integration.nim"
  exec "nim c -r tests/test_record.nim"
  exec "nim c -r tests/test_error_handling.nim"
  echo ""
  echo "=== Running Demos ==="
  exec "nim c -r samples/basic_demo.nim"
  echo ""
  echo "=== All Tests Completed Successfully ==="

# Clean task - remove generated data files only (not source code)

task clean, "Clean up generated data files":
  exec "rm -f test_*.data"
  exec "rm -f tests/*.data"
  exec "rm -f bench/*.data"
  exec "rm -f samples/*.data"
  exec "rm -f examples/*.data"
  # Remove compiled test binaries
  exec "rm -f tests/test_storage tests/test_keydir tests/test_integration"
  exec "rm -f bench/simple_bench bench/stress_test"
  exec "rm -f samples/basic_demo samples/simple_kv_demo"
  echo "Cleaned up generated data files and binaries"