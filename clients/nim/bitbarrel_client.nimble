# Package

version       = "0.1.0"
author        = "Göran Krampe"
description   = "BitBarrel network client library for Nim"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.6"
requires "https://github.com/gokr/whisky"     # Websocket client library

# Tasks

task syncProtocol, "Sync protocol.nim from server source":
  ## Copies the protocol.nim file from the main BitBarrel server source
  ## to keep client and server protocol definitions in sync.
  let serverProtocol = "../../src/network/protocol.nim"
  let clientProtocol = "src/bitbarrel_client/protocol.nim"

  if not fileExists(serverProtocol):
    echo "Error: Server protocol.nim not found at ", serverProtocol
    echo "Make sure you're running this from the clients/nim directory"
    quit(1)

  cpFile(serverProtocol, clientProtocol)
  echo "Synced protocol.nim from server source"

task test, "Run all tests (automatic discovery)":
  exec """
    # Find and run all test_*.nim files in tests directory
    echo "Running Nim client tests..."
    set -e  # Exit on first failure
    for test_file in tests/test_*.nim; do
      if [ -f "$test_file" ]; then
        echo ""
        echo "=========================================="
        echo "Running: $test_file"
        echo "=========================================="
        nim c -r "$test_file"
      fi
    done
    echo ""
    echo "✓ All tests passed!"
  """

task testPubSub, "Run pub/sub tests (requires running server)":
  exec "nim c -r tests/test_pubsub.nim"

task testIntegration, "Run integration tests (requires running server)":
  exec "nim c -r -d:integration tests/test_client.nim"

task docs, "Generate documentation":
  exec "nim doc --project --index:on --outdir:docs src/bitbarrel_client.nim"
