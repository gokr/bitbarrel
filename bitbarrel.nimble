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
requires "sunny"                             # Fast JSON library
 
# Task for testing

task checkDocExamples, "Verify all .compilable code blocks in docs compile":
  exec "nim c -r tools/check_doc_examples.nim"

task checkExamples, "Compile all examples and benchmarks (verification check) - exits on first error":
  exec """
    # Exit on first error
    set -e

    # Compile all examples (excluding utility modules)
    # Note: pubsub examples require --path:clients/nim/src to find bitbarrel_client
    find examples -name "*.nim" -type f | grep -v "pubsub/" | while IFS= read -r file; do
      echo "Compiling $file..."
      nim c --verbosity:0 --path:src --path:clients/nim/src "$file"
    done

    # Compile all benchmarks
    find bench -name "*.nim" -type f | while IFS= read -r file; do
      echo "Compiling $file..."
      nim c --verbosity:0 --path:src "$file"
    done

    echo "✓ All examples (except pubsub) and benchmarks compiled successfully!"
  """

task checkCompilation, "Run all compilation checks (doc examples, examples, benchmarks)":
  exec """
    echo "=== Checking documentation examples ==="
    nimble checkDocExamples
    echo ""
    echo "=== Checking examples and benchmarks ==="
    nimble checkExamples
    echo "✓ All compilation checks passed!"
  """

task buildWebAdmin, "Build Flutter webadmin":
  exec "cd webadmin && flutter build web --release"

task buildAll, "Run all build tasks (checkCompilation + buildWebAdmin)":
  exec """
    echo "=== Running compilation checks ==="
    nimble checkCompilation
    echo ""
    echo "=== Building webadmin ==="
    nimble buildWebAdmin
    echo "✓ All build tasks completed successfully!"
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

task testPubSub, "Run pub/sub tests - automatic discovery":
  exec "testament pattern \"tests/pubsub/*.nim\""

task testPubSubTypes, "Run pub/sub types tests":
  exec "testament pattern \"tests/pubsub/test_pubsub_types.nim\""

task testPubSubPattern, "Run pattern matching tests":
  exec "testament pattern \"tests/pubsub/test_pattern.nim\""

task testPubSubManager, "Run manager tests":
  exec "testament pattern \"tests/pubsub/test_manager.nim\""

task testPubSubHooks, "Run barrel hooks tests":
  exec "testament pattern \"tests/pubsub/test_barrel_hooks.nim\""

task testPubSubHistory, "Run history tests":
  exec "testament pattern \"tests/pubsub/test_history.nim\""

task testPubSubIntegration, "Run pub/sub integration tests":
  exec "testament pattern \"tests/pubsub/test_integration.nim\""

task testHookSystem, "Run query result hooks hook system tests":
  exec "testament pattern \"tests/plugins/*.nim\""

# Tasks for running examples

task exampleBasic, "Run basic CRUD example":
  exec "nim r examples/basic/basic.nim"

task examplePerformance, "Run performance example":
  exec "nim r examples/basic/performance.nim"

task exampleGraph, "Run graph traversal example":
  exec "nim r examples/advanced/graph_traversal.nim"

task exampleAdvanced, "Run advanced features example":
  exec "nim r examples/advanced/advanced.nim"

task exampleNetworkBasic, "Run basic network example":
  exec "nim r examples/networking/basic_client.nim"

task exampleNetworkBarrels, "Run network barrels example":
  exec "nim r examples/networking/barrels_example.nim"

task exampleHooks, "Run hook system examples":
  exec "nim r examples/plugins/range_query_plugins.nim"

# Backward compatibility aliases
task demoBasic, "Run basic CRUD demo (deprecated: use exampleBasic)":
  exec "nim r examples/basic/basic.nim"

task demoPerformance, "Run performance demo (deprecated: use examplePerformance)":
  exec "nim r examples/basic/performance.nim"

task demoGraph, "Run graph traversal demo (deprecated: use exampleGraph)":
  exec "nim r examples/advanced/graph_traversal.nim"

task demoAdvanced, "Run advanced features demo (deprecated: use exampleAdvanced)":
  exec "nim r examples/advanced/advanced.nim"

task demoNetworkBasic, "Run basic network demo (deprecated: use exampleNetworkBasic)":
  exec "nim r examples/networking/basic_client.nim"

task demoNetworkBarrels, "Run network barrels demo (deprecated: use exampleNetworkBarrels)":
  exec "nim r examples/networking/barrels_example.nim"

# Task for benchmarking

task bench, "Run comprehensive benchmark suite":
  exec "nim c -d:release -r --path:src bench/unified_benchmark.nim"

task benchQuick, "Run quick benchmark (1000 ops)":
  exec "nim c -d:release -r --path:src bench/unified_benchmark.nim quick"

task benchComprehensive, "Run comprehensive benchmark (100K ops)":
  exec "nim c -d:release -r --path:src bench/unified_benchmark.nim comprehensive"

task benchCrunchy, "Run performance benchmark with crunchy CRC32":
  exec "nim c -d:release -d:useCrunchy -r bench/simple_bench.nim"

task benchMySQL, "Run BitBarrel vs MySQL performance comparison":
  exec "nim c -d:release -d:useMySQL -r --path:src bench/mysql_comparison.nim"

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

task testNimClient, "Test Nim client library - starts server on port 9876":
  exec "./tools/test_client.sh nim"

task testGoClient, "Test Go client library - starts server on port 9876":
  exec "./tools/test_client.sh go"

task testPythonClient, "Test Python client library - starts server on port 9876":
  exec "./tools/test_client.sh python"

task testDartClient, "Test Dart client library - starts server on port 9876":
  exec "./tools/test_client.sh dart"

task testTypeScriptClient, "Test TypeScript client library - starts server on port 9876":
  exec "./tools/test_client.sh typescript"

task testCClient, "Test C client library - starts server on port 9876":
  exec "./tools/test_client.sh c"

task testZigClient, "Test Zig client library - starts server on port 9876":
  exec "./tools/test_client.sh zig"

task testClients, "Test all client libraries (Python, Go, Dart, Nim, TypeScript, C, Zig) - starts server on port 9876":
  exec "./tools/test_client.sh c go python dart nim typescript zig"

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

task dockerBuild, "Build Docker image (builds bitbarrel and webadmin in multi-stage)":
  exec """
    echo "Building Docker image..."
    docker build -t bitbarrel:latest .
  """

task dockerRun, "Run BitBarrel in Docker container":
  exec "docker run -d -p 8080:8080 -v bitbarrel-data:/data bitbarrel:latest"

task dockerComposeUp, "Run BitBarrel using Docker Compose":
  exec "docker compose up -d"

task dockerComposeDown, "Stop BitBarrel Docker Compose":
  exec "docker compose down"

task dockerComposeLogs, "View BitBarrel logs from Docker Compose":
  exec "docker compose logs -f"

task dockerPublish, "Build and publish Docker image to registry":
  exec """
    echo "Building Docker image..."
    nimble dockerBuild
    echo "Publishing to registry..."
    docker push bitbarrel:latest
  """

# Client library assessment tasks

task assessClients, "Assess all BitBarrel client libraries and generate report":
  exec "python3 tools/assess_clients.py"

task assessClientsBrief, "Brief client library assessment summary":
  exec "python3 tools/assess_clients.py --brief"

task assessClientsJSON, "Generate JSON report of client library assessment":
  exec "python3 tools/assess_clients.py --json > client-assessment.json"

task assessClientsUpdateDocs, "Update client libraries assessment documentation":
  exec """
    echo "Running client library assessment..."
    python3 tools/assess_clients.py --json > docs/client-assessment-data.json
    echo "Update docs/CLIENT_LIBRARIES.md with latest data"
    echo "Assessment completed on $(date)" >> docs/CLIENT_LIBRARIES.md
  """

task assessClientsDetailed, "Detailed assessment of each client library":
  exec "python3 tools/assess_clients.py --detailed"
