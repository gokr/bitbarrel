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
requires "jwt"             # JWT authentication
requires "supersnappy"      # For optional Snappy support
requires "https://github.com/gokr/lz4wrapper" # For optional LZ4 support
requires "https://github.com/gokr/mummy"      # MummyX WebSocket/HTTP server
requires "https://github.com/gokr/whisky"     # Websocket client library
 
# Task for testing

task checkDocExamples, "Verify all .compilable code blocks in docs compile":
  exec "nim c -r tools/check_doc_examples.nim"

task checkDemos, "Compile all demos and benchmarks (verification check) - exits on first error":
  exec """
    # Exit on first error
    set -e

    # Compile all demos (demo_utils.nim is excluded as it's a utility module)
    find demos -name "*.nim" -type f | grep -v demo_utils.nim | while IFS= read -r file; do
      echo "Compiling $file..."
      nim c --verbosity:0 --path:src "$file"
    done

    # Compile all benchmarks
    find bench -name "*.nim" -type f | while IFS= read -r file; do
      echo "Compiling $file..."
      nim c --verbosity:0 --path:src "$file"
    done

    echo "✓ All demos and benchmarks compiled successfully!"
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
  exec "nim r demos/basic_demo.nim"

task demoPerformance, "Run performance demo":
  exec "nim r demos/performance_demo.nim"

task demoGraph, "Run graph traversal demo":
  exec "nim r demos/graph_demo.nim"

task demoAdvanced, "Run advanced features demo":
  exec "nim r demos/advanced_demo.nim"

task demoNetworkBasic, "Run basic network demo":
  exec "nim r demos/network/basic.nim"

task demoNetworkBarrels, "Run network barrels demo":
  exec "nim r demos/network/barrels.nim"

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

# HugeBarrel stress tests

task stressHugeQuick, "Run HugeBarrel stress test (quick - 1M keys, ~2GB)":
  exec "nim c -d:release -r --path:src bench/hugebarrel_stress.nim quick"

task stressHugeStandard, "Run HugeBarrel stress test (standard - 10M keys, ~20GB)":
  exec "nim c -d:release -r --path:src bench/hugebarrel_stress.nim standard"

task stressHugeStress, "Run HugeBarrel stress test (stress - 50M keys, ~50GB)":
  exec "nim c -d:release -r --path:src bench/hugebarrel_stress.nim stress"

task stressHugeExhaustive, "Run HugeBarrel stress test (exhaustive - full validation)":
  exec "nim c -d:release -r --path:src bench/hugebarrel_stress.nim exhaustive"

task stressHugeAll, "Run all HugeBarrel stress test profiles":
  exec """
    echo "Running HugeBarrel stress tests..."
    echo ""
    echo "=== Quick Profile (1M keys) ==="
    nim c -d:release -r --path:src bench/hugebarrel_stress.nim quick
    echo ""
    echo "=== Standard Profile (10M keys) ==="
    nim c -d:release -r --path:src bench/hugebarrel_stress.nim standard
    echo ""
    echo "=== Stress Profile (50M keys) ==="
    nim c -d:release -r --path:src bench/hugebarrel_stress.nim stress
  """

# Tasks for network server and client

task client, "Build BitBarrel network client library":
  exec "nim c -d:release --mm:orc --threads:on -o:bitbarrel_client src/network/client.nim"

task testNetwork, "Run network integration tests - automatic discovery":
  exec "testament pattern \"tests/network/*/*.nim\""

task benchNetwork, "Run network benchmark (1000 ops)":
  exec "nim c -d:release --mm:orc --threads:on -r --path:src bench/network_bench.nim quick"

task benchNetworkComprehensive, "Run comprehensive network benchmark (100K ops, 10 clients)":
  exec "nim c -d:release --mm:orc --threads:on -r --path:src bench/network_bench.nim comprehensive"

# Test all client libraries - starts server, runs tests, stops server

task testClients, "Test all client libraries (Python, Go, Dart, Nim) - starts server on port 9876":
  exec """
    # Start BitBarrel server in background
    echo "Starting BitBarrel server on port 9876..."
    ./bitbarrel -p=9876 serve > /tmp/bitbarrel_server.log 2>&1 &
    SERVER_PID=$!

    # Give server time to start
    sleep 2

    # Check if server started successfully
    if ! kill -0 $SERVER_PID 2>/dev/null; then
      echo "ERROR: Failed to start BitBarrel server"
      cat /tmp/bitbarrel_server.log
      exit 1
    fi

    echo "✓ Server started (PID: $SERVER_PID)"

    # Function to stop server on exit
    cleanup() {
      echo ""
      echo "Stopping BitBarrel server..."
      kill $SERVER_PID 2>/dev/null
      wait $SERVER_PID 2>/dev/null
      echo "✓ Server stopped"
    }
    trap cleanup EXIT

    # Track overall success
    ALL_PASSED=true

    # Test Go client
    if [ -d "clients/go" ]; then
      echo ""
      echo "=== Testing Go client ==="
      if [ -f "clients/go/go.mod" ]; then
        cd clients/go
        # Run only package tests (not examples), with server environment
        export BITBARREL_TEST_SERVER=true
        if go test -v $(go list ./... | grep -v examples); then
          echo "✓ Go client tests passed"
        else
          echo "✗ Go client tests failed"
          ALL_PASSED=false
        fi
        cd ../..
      else
        echo "⚠ Go client has no go.mod, skipping"
      fi
    fi

    # Test Python client
    if [ -d "clients/python" ]; then
      echo ""
      echo "=== Testing Python client ==="
      ORIG_DIR=$(pwd)
      if [ -f "clients/python/venv/bin/activate" ]; then
        cd clients/python
        # Use . instead of source for sh compatibility
        . venv/bin/activate
        # Add the package to Python path
        PYTHONPATH=.:$PYTHONPATH pytest tests/test_client.py -v
        TEST_RESULT=$?
        deactivate
        cd "$ORIG_DIR"
        if [ $TEST_RESULT -eq 0 ]; then
          echo "✓ Python client tests passed"
        else
          echo "✗ Python client tests failed"
          ALL_PASSED=false
        fi
      else
        echo "⚠ Python client has no venv, trying system Python..."
        cd clients/python
        PYTHONPATH=.:$PYTHONPATH pytest tests/test_client.py -v
        if [ $? -eq 0 ]; then
          echo "✓ Python client tests passed"
        else
          echo "✗ Python client tests failed"
          ALL_PASSED=false
        fi
        cd "$ORIG_DIR"
      fi
    fi

    # Test Dart client
    if [ -d "clients/dart" ]; then
      echo ""
      echo "=== Testing Dart client ==="
      if [ -f "clients/dart/pubspec.yaml" ]; then
        cd clients/dart
        if which dart >/dev/null 2>&1; then
          if dart test 2>/dev/null; then
            echo "✓ Dart client tests passed"
          else
            echo "⚠ Dart client tests not found or failed"
          fi
        else
          echo "⚠ Dart not installed, skipping"
        fi
        cd ../..
      else
        echo "⚠ Dart client has no pubspec.yaml, skipping"
      fi
    fi

    # Test Nim client
    if [ -d "clients/nim" ]; then
      echo ""
      echo "=== Testing Nim client ==="
      if [ -f "clients/nim/bitbarrel_client.nimble" ]; then
        cd clients/nim
        if nimble test 2>/dev/null; then
          echo "✓ Nim client tests passed"
        else
          echo "⚠ Nim client tests not configured or failed"
        fi
        cd ../..
      else
        echo "⚠ Nim client has no nimble file, skipping"
      fi
    fi

    echo ""
    echo "=== Summary ==="
    if [ "$ALL_PASSED" = true ]; then
      echo "✓ All client library tests passed"
    else
      echo "✗ Some client library tests failed"
      exit 1
    fi
    echo ""
    echo "Server log (last 20 lines):"
    tail -20 /tmp/bitbarrel_server.log
  """

# Compression build tasks
task buildLz4, "Build with LZ4 compression (default)":
  exec "nim c -d:release src/bitbarrel.nim"

task buildSnappy, "Build with Snappy compression":
  exec "nim c -d:snappyCompression -d:release src/bitbarrel.nim"

task buildNoCompression, "Build without compression":
  exec "nim c -d:noCompression -d:release src/bitbarrel.nim"

task buildDefault, "Build with default settings (LZ4 compression)":
  exec "nim c -d:release src/bitbarrel.nim"

task build, "Build with default settings (LZ4 compression)":
  exec "nim c -d:release src/bitbarrel.nim"

# Docker tasks

task dockerBuild, "Build Docker image with web admin":
  exec "./build_docker.sh"

task dockerBuildNoTest, "Build Docker image without running tests":
  exec "./build_docker.sh --skip-test"

task dockerRun, "Run BitBarrel in Docker container":
  exec "docker run -d -p 8080:8080 -p 8081:8081 -v bitbarrel-data:/data bitbarrel:latest"

task dockerComposeUp, "Run BitBarrel using Docker Compose":
  exec "docker-compose up -d"

task dockerComposeDown, "Stop BitBarrel Docker Compose":
  exec "docker-compose down"

task dockerComposeLogs, "View BitBarrel logs from Docker Compose":
  exec "docker-compose logs -f"

task dockerPublish, "Build and publish Docker image to registry":
  exec "./build_docker.sh --publish"
