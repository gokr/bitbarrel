#!/bin/bash

# BitBarrel Admin Console Start Script
# Starts BitBarrel server and Flutter web admin

set -e

echo "=== BitBarrel Admin Console ==="
echo

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Function to cleanup on exit
cleanup() {
    echo
    echo "Shutting down..."
    if [ ! -z "$SERVER_PID" ]; then
        echo "Stopping BitBarrel server (PID: $SERVER_PID)..."
        kill $SERVER_PID 2>/dev/null || true
        wait $SERVER_PID 2>/dev/null || true
    fi
    exit 0
}

# Set up trap to catch Ctrl+C
trap cleanup INT TERM

# Check if BitBarrel binary exists
if [ ! -f "./bitbarrel" ]; then
    echo "Error: bitbarrel binary not found. Please build it first:"
    echo "  nimble build"
    exit 1
fi

# Check if Flutter is installed
if ! command -v flutter &> /dev/null; then
    echo "Error: Flutter is not installed or not in PATH"
    echo "Please install Flutter from https://flutter.dev"
    exit 1
fi

# Start BitBarrel server in background
echo "Starting BitBarrel server..."
./bitbarrel serve -p 9876 > /tmp/bitbarrel_server.log 2>&1 &
SERVER_PID=$!

# Wait for server to start
echo "Waiting for server to start..."
sleep 2

# Check if server started successfully
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Error: Failed to start BitBarrel server"
    echo "Check logs: tail -f /tmp/bitbarrel_server.log"
    exit 1
fi

echo "✓ BitBarrel server started (PID: $SERVER_PID)"
echo

# Change to webadmin directory
cd webadmin

# Install dependencies if needed
if [ ! -d ".dart_tool" ]; then
    echo "Installing Flutter dependencies..."
    flutter pub get
fi

# Build and start the web admin
echo "Starting Flutter web admin..."
echo "The admin console will open in your browser"
echo "Press Ctrl+C to stop both server and admin"
echo

# Run Flutter web on a specific port
flutter run -d chrome --web-port 8080

# Cleanup is handled by the trap
cleanup
