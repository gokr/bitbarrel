#!/bin/bash

# Helper script to test a specific client library
# Usage: ./tools/test_client.sh <client_name>
# Where <client_name> is one of: nim, go, python, dart, typescript

set -e

CLIENT_NAME=$1

if [ -z "$CLIENT_NAME" ]; then
  echo "ERROR: Client name required"
  echo "Usage: $0 <client_name>"
  echo "Client names: nim, go, python, dart, typescript"
  exit 1
fi

# Start BitBarrel server in background
echo "Starting BitBarrel server on port 9876..."
./bitbarrel -p=9876 serve > /tmp/bitbarrel_server.log 2>&1 &
SERVER_PID=$!

# Give server time to start
sleep 5

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
  kill $SERVER_PID 2>/dev/null || true
  wait $SERVER_PID 2>/dev/null || true
  echo "✓ Server stopped"
}
trap cleanup EXIT

# Change to the client directory
cd "clients/$CLIENT_NAME"

# Run client-specific tests
case $CLIENT_NAME in
  nim)
    if [ ! -f "bitbarrel_client.nimble" ]; then
      echo "⚠ Nim client has no nimble file, skipping"
      exit 0
    fi
    nimble test
    ;;
  go)
    if [ ! -f "go.mod" ]; then
      echo "⚠ Go client has no go.mod, skipping"
      exit 0
    fi
    export BITBARREL_TEST_SERVER=true
    go test -v $(go list ./... | grep -v examples)
    ;;
  python)
    if [ -f "venv/bin/activate" ]; then
      . venv/bin/activate
      PYTHONPATH=.:$PYTHONPATH pytest tests/ -v
      TEST_RESULT=$?
      deactivate
      exit $TEST_RESULT
    else
      echo "⚠ Python client has no venv, trying system Python..."
      PYTHONPATH=.:$PYTHONPATH pytest tests/ -v
    fi
    ;;
  dart)
    if [ ! -f "pubspec.yaml" ]; then
      echo "⚠ Dart client has no pubspec.yaml, skipping"
      exit 0
    fi
    if ! which dart >/dev/null 2>&1; then
      echo "⚠ Dart not installed, skipping"
      exit 0
    fi
    dart test
    ;;
  typescript)
    if [ ! -f "package.json" ]; then
      echo "⚠ TypeScript client package.json not found, skipping"
      exit 0
    fi
    npm test
    ;;
  *)
    echo "ERROR: Unknown client '$CLIENT_NAME'"
    exit 1
    ;;
esac
