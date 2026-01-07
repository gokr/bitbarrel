#!/bin/bash

# BitBarrel Web Admin Build Script
# Builds the web admin for production with correct base href

set -e

echo "=== Building BitBarrel Web Admin ==="
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
    echo
fi

# Build for production with correct base href and optimizations
echo "Building for production with base href /admin/..."
echo "Optimizations enabled: minification, tree-shaking, dart2js -O4"
flutter build web --release --base-href /admin/

echo
echo "✓ Build complete!"
echo "Output: build/web/"
echo
echo "To serve with BitBarrel:"
echo "  cd .."
echo "  ./bitbarrel serve --webadmin-path=./webadmin/build/web"
echo
