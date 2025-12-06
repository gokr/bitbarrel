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
  exec "nim test tests/test_storage.nim"
  exec "nim test tests/test_keydir.nim"
  exec "nim test tests/test_concurrency.nim"
  exec "nim test tests/test_network.nim"

# Task for benchmarking

task bench, "Run benchmarks":
  exec "nim c -r -d:release tests/bench/benchmark.nim"

# Task for building server

task server, "Build KVS server":
  exec "nim c -d:release src/server.nim"

# Task for building client

task client, "Build KVS client":
  exec "nim c -d:release src/client.nim"