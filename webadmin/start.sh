#!/bin/bash

# BitBarrel Web Admin Start Script
# Starts Flutter web admin in development mode

set -e

echo "=== BitBarrel Web Admin ==="
echo

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Check if Flutter is installed
if ! command -v flutter &> /dev/null; then
    echo "Error: Flutter is not installed or not in PATH"
    echo "Please install Flutter from https://flutter.dev"
    exit 1
fi

# Install dependencies if needed
if [ ! -d ".dart_tool" ]; then
    echo "Installing Flutter dependencies..."
    flutter pub get
fi

# Start the web admin
echo "Starting Flutter web admin in Chrome..."
echo "The admin console will open in your browser at http://localhost:8080"
echo "Press 'q' or Ctrl+C to stop"
echo

# Run Flutter web on Chrome at port 8080
flutter run -d chrome --web-port 8080
