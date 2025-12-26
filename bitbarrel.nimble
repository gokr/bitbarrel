# Package

version       = "0.5.0"
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
requires "https://github.com/gokr/mummy"      # MummyX WebSocket/HTTP server
requires "https://github.com/gokr/whisky"     # Websocket client library
 
# Task for testing

task checkDocExamples, "Verify all .compilable code blocks in docs compile":
  exec "nim c -r tools/check_doc_examples.nim"

task checkExamples, "Compile all examples and benchmarks (verification check) - exits on first error":
  exec """
    # Exit on first error
    set -e

    # Compile all examples (demo_utils.nim is excluded as it's a utility module)
    find examples -name "*.nim" -type f | grep -v demo_utils.nim | while IFS= read -r file; do
      echo "Compiling $file..."
      nim c --verbosity:0 --path:src "$file"
    done

    # Compile all benchmarks
    find bench -name "*.nim" -type f | while IFS= read -r file; do
      echo "Compiling $file..."
      nim c --verbosity:0 --path:src "$file"
    done

    echo "✓ All examples and benchmarks compiled successfully!"
  """

task test, "Run all tests (automatic discovery via testament)":
  exec """
    echo "Running BitBarrel test suite..."
    echo "=== Running tests/test_*.nim ==="
    testament pattern "tests/test_*.nim" || true
    echo "=== Running tests/category/*.nim ==="
    testament pattern "tests/**/*.nim" || true
    echo "=== Running tests/category/subcategory/*.nim ==="
    testament pattern "tests/**/**/*.nim" || true
  """

# Testament-based test tasks with automatic discovery

task testStorage, "Run storage tests (unit/storage)":
  exec "testament pattern \"tests/unit/storage/*.nim\""

task testKeydir, "Run KeyDir tests (unit/keydir)":
  exec "testament pattern \"tests/unit/keydir/*.nim\""

task testIntegration, "Run integration tests (system/integration)":
  exec "testament pattern \"tests/system/integration/*.nim\""

task testRecovery, "Run recovery tests":
  exec "testament pattern \"tests/recovery/*.nim\""

task testUnit, "Run unit tests (low-level components) - automatic discovery":
  exec "testament pattern \"tests/unit/*/*.nim\""

task testAPI, "Run API tests (high-level Barrel API) - automatic discovery":
  exec "testament pattern \"tests/api/*/*.nim\""

task testSystem, "Run system tests (full system behavior) - automatic discovery":
  exec "testament pattern \"tests/system/*/*.nim\""

task testError, "Run error handling tests (API error category) - automatic discovery":
  exec "testament pattern \"tests/api/error/*.nim\""

task testHugeBarrel, "Run HugeBarrel feature tests - automatic discovery":
  exec "testament pattern \"tests/hugebarrel/*.nim\""

# Tasks for running demos

task demoBasic, "Run basic CRUD demo":
  exec "nim c -r --path:src examples/basic_demo.nim"

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

task stressCompact, "Run compaction stress test (quick - 10K ops)":
  exec "nim c -d:release -r --path:src bench/compaction_stress.nim quick"

task stressCompactStandard, "Run compaction stress test (standard - 100K ops)":
  exec "nim c -d:release -r --path:src bench/compaction_stress.nim standard"

task stressCompactHeavy, "Run compaction stress test (stress - 1M ops)":
  exec "nim c -d:release -r --path:src bench/compaction_stress.nim stress"

# Tasks for network server and client

task client, "Build BitBarrel network client library":
  exec "nim c -d:release --mm:orc --threads:on -o:bitbarrel_client src/network/client.nim"

task testNetwork, "Run network integration tests - automatic discovery":
  exec "testament pattern \"tests/network/*/*.nim\""

task benchNetwork, "Run network benchmark (1000 ops)":
  exec "nim c -d:release --mm:orc --threads:on -r --path:src bench/network_bench.nim quick"

task benchNetworkComprehensive, "Run comprehensive network benchmark (100K ops, 10 clients)":
  exec "nim c -d:release --mm:orc --threads:on -r --path:src bench/network_bench.nim comprehensive"


# Clean task - remove generated data files only (not source code)

task clean, "Clean up generated data files":
  exec "rm -f test_*.data"
  exec "rm -f tests/*.data"
  exec "rm -f bench/*.data"
  exec "rm -f bench_*.data"
  exec "rm -f examples/*.data"
  # Remove compiled test binaries
  exec "rm -f tests/test_storage tests/test_keydir tests/test_integration tests/test_recovery"
  exec "rm -f bench/simple_bench bench/stress_test bench/compaction_stress"
  exec "rm -f examples/basic_demo"
  echo "Cleaned up generated data files and binaries"

# Build with compression support

task build, "Build with LZ4 compression (default)":
  echo "Building BitBarrel with LZ4 compression (default)..."
  exec "nim c -d:lz4Compression -d:release src/bitbarrel.nim"

task buildDefault, "Build with LZ4 compression (default)":
  echo "Building BitBarrel with LZ4 compression (default)..."
  exec "nim c -d:lz4Compression -d:release src/bitbarrel.nim"

task buildLz4, "Build with LZ4 compression support":
  echo "Building BitBarrel with LZ4 compression..."
  exec "nim c -d:lz4Compression -d:release src/bitbarrel.nim"

task buildSnappy, "Build with Snappy compression support":
  echo "Building BitBarrel with Snappy compression..."
  exec "nim c -d:snappyCompression -d:release src/bitbarrel.nim"

task buildNoCompression, "Build without compression":
  echo "Building BitBarrel without compression..."
  exec "nim c -d:release src/bitbarrel.nim"

# Documentation generation tasks

task genDocs, "Generate HTML documentation using nim doc":
  exec "mkdir -p docs/html"
  exec "rm -rf docs/html/*.html"
  exec "nim doc --out:docs/html/bitbarrel.html --project src/bitbarrel.nim"
  exec "nim doc --out:docs/html/client.html --project src/network/client.nim"
  echo "Documentation generated in docs/html/"

task docServer, "Serve documentation locally (assumes Python is installed)":
  try:
    exec "cd docs/html && python3 -m http.server 8000"
  except:
    try:
      exec "cd docs/html && python -m SimpleHTTPServer 8000"
    except:
      echo "Please manually serve docs/html/ folder with your web server"
      echo "Or open docs/html/index.html in your browser"