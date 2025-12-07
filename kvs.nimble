# Package

version       = "0.1.0"
author        = "KVS Team"
description   = "High-Performance Bitcask Key/Value Store"
license       = "MIT"

# Source directory
srcDir        = "src"

# Dependencies

requires "nim >= 2.0"

# Task for testing

task test, "Run all tests":
  exec "nim c -r tests/test_storage.nim"
  exec "nim c -r tests/test_keydir.nim"
  exec "nim c -r tests/test_integration.nim"

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

# Full test - tests + demos + benchmarks

task fullTest, "Run full test suite":
  echo "=== Running Tests ==="
  exec "nim c -r tests/test_storage.nim"
  exec "nim c -r tests/test_keydir.nim"
  exec "nim c -r tests/test_integration.nim"
  echo ""
  echo "=== Running Demos ==="
  exec "nim c -r samples/basic_demo.nim"
  echo ""
  echo "=== All Tests Completed Successfully ==="

# Clean task - remove test files

task clean, "Clean up test and bench files":
  exec "rm -f test_*.data"
  exec "rm -f bench/*.data"
  exec "rm -f samples/*.data"
  exec "rm -f examples/*.data"
  exec "rm -rf bench/"
  exec "rm -rf samples/"
  echo "Cleaned up all test and temporary files"