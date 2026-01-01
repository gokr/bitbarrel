#!/bin/sh
set -e

# BitBarrel Docker Entrypoint Script
# Handles starting both bitbarrel server and Flutter web admin

# Configuration
BITBARREL_DATA_DIR="${BITBARREL_STORAGE_DATA_DIR:-/data}"
BITBARREL_SERVER_PORT="${BITBARREL_SERVER_PORT:-8080}"
BITBARREL_ADMIN_PORT="${BITBARREL_ADMIN_PORT:-8081}"
BITBARREL_SERVER_ADDRESS="${BITBARREL_SERVER_ADDRESS:-0.0.0.0}"
BITBARREL_AUTH_ENABLED="${BITBARREL_AUTH_ENABLED:-false}"

# Ensure data directory exists
mkdir -p "${BITBARREL_DATA_DIR}"

# Generate JWT secret if auth is enabled but no secret provided
if [ "${BITBARREL_AUTH_ENABLED}" = "true" ] && [ -z "${BITBARREL_AUTH_SECRET}" ]; then
    echo "Warning: Authentication enabled but no secret provided. Generating random secret."
    echo "Set BITBARREL_AUTH_SECRET environment variable to use a persistent secret."
    BITBARREL_AUTH_SECRET=$(openssl rand -base64 32)
    export BITBARREL_AUTH_SECRET
fi

# Function to cleanup on exit
cleanup() {
    echo "Shutting down BitBarrel services..."
    if [ ! -z "${SERVER_PID}" ]; then
        kill ${SERVER_PID} 2>/dev/null || true
        wait ${SERVER_PID} 2>/dev/null || true
    fi
    if [ ! -z "${ADMIN_PID}" ]; then
        kill ${ADMIN_PID} 2>/dev/null || true
        wait ${ADMIN_PID} 2>/dev/null || true
    fi
    exit 0
}

# Set up signal handlers
trap cleanup TERM INT

# Start BitBarrel server in background
echo "Starting BitBarrel server on ${BITBARREL_SERVER_ADDRESS}:${BITBARREL_SERVER_PORT}..."
/usr/local/bin/bitbarrel serve \
    --port=${BITBARREL_SERVER_PORT} \
    --data-dir=${BITBARREL_DATA_DIR} \
    --config=/dev/null &  # Use /dev/null to ignore config file, use env vars only

SERVER_PID=$!

# Wait for server to start
sleep 2

# Check if server started successfully
if ! kill -0 ${SERVER_PID} 2>/dev/null; then
    echo "Error: Failed to start BitBarrel server"
    exit 1
fi

echo "✓ BitBarrel server started (PID: ${SERVER_PID})"

# Start Flutter web admin
# Use simpleHTTP to serve the web admin
# The admin connects to the server at window.location.hostname:BITBARREL_SERVER_PORT
if [ -d "/opt/bitbarrel/webadmin" ]; then
    echo "Starting Flutter web admin on port ${BITBARREL_ADMIN_PORT}..."

    # Create a simple HTTP server for the Flutter web app
    # Python's http.server is not available in Alpine by default, so we use a simple approach
    # The admin will connect to the server using the same hostname
    cd /opt/bitbarrel/webadmin

    # Use a background Python HTTP server if available, otherwise use busybox httpd
    if command -v python3 >/dev/null 2>&1; then
        python3 -m http.server ${BITBARREL_ADMIN_PORT} &
    elif command -v busybox >/dev/null 2>&1; then
        busybox httpd -f -p ${BITBARREL_ADMIN_PORT} &
    else
        echo "Warning: No HTTP server available for web admin"
    fi

    ADMIN_PID=$!

    # Wait for admin to start
    sleep 1

    if kill -0 ${ADMIN_PID} 2>/dev/null; then
        echo "✓ Flutter web admin started (PID: ${ADMIN_PID})"
        echo ""
        echo "BitBarrel is ready!"
        echo "  Server: ${BITBARREL_SERVER_ADDRESS}:${BITBARREL_SERVER_PORT}"
        echo "  Web Admin: http://localhost:${BITBARREL_ADMIN_PORT}"
        echo "  Data Directory: ${BITBARREL_DATA_DIR}"
        echo ""
        echo "Press Ctrl+C to stop"
    else
        echo "Warning: Failed to start web admin, continuing without it"
    fi
else
    echo "Warning: Web admin not found at /opt/bitbarrel/webadmin"
fi

# Wait for either process to exit
wait ${SERVER_PID}

# If server exits, cleanup and exit
cleanup
