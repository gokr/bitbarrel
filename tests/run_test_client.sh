#!/bin/bash
# Test runner that starts server in separate process

echo "Starting BitBarrel test server..."

# Create temp directory for test data
TEST_DATA_DIR=$(mktemp -d /tmp/bitbarrel_test_XXXXXX)

# Trap to ensure cleanup always happens
cleanup() {
  echo "Cleaning up..."
  kill $SERVER_PID 2>/dev/null || true
  wait $SERVER_PID 2>/dev/null || true
  rm -rf "$TEST_DATA_DIR"
}

trap cleanup EXIT

# Start server in background
echo "Starting server on port 8081..."
./tests/test_server_process "$TEST_DATA_DIR" &
SERVER_PID=$!

# Wait for server to be ready by checking HTTP endpoint
echo "Waiting for server to be ready..."
MAX_WAIT=15
WAITED=0
while true; do
  RESPONSE=$(curl -sS http://127.0.0.1:8081/status 2>&1)
  if echo "$RESPONSE" | grep -q '"status".*"ok"'; then
    echo "Got OK response from server"
    break
  fi
  if [ -n "$RESPONSE" ]; then
    echo "DEBUG: Got response: $RESPONSE"
  fi
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo "ERROR: Server did not become ready within ${MAX_WAIT}s"
    echo "Last response: $RESPONSE"
    exit 1
  fi
  sleep 0.5
  WAITED=$((WAITED + 1))
done
echo "Server is ready (waited ${WAITED}s)"

# Give server extra time to fully initialize WebSocket handlers
echo "Waiting extra time for WebSocket handler..."
sleep 5

echo "Running client tests..."
# Run client tests (without starting server in thread)
./tests/test_client_no_server
TEST_RESULT=$?

if [ $TEST_RESULT -eq 0 ]; then
  echo "All tests passed!"
else
  echo "Tests failed with exit code: $TEST_RESULT"
fi

exit $TEST_RESULT
