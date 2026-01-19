#!/bin/bash
# Simple build script for BitBarrel C library

set -e

echo "Building BitBarrel C Library..."
echo "================================="

# Create build directory
mkdir -p build
cd build

# Configure with CMake
echo "Configuring with CMake..."
cmake .. "$@"

# Build
echo "Building..."
make -j$(nproc)

# Run tests
echo ""
echo "Running tests..."
ctest --verbose || echo "Tests completed (some may fail without server)"

echo ""
echo "✓ Build completed successfully!"
echo ""
echo "To install system-wide:"
echo "  cd build && sudo make install"
echo ""
echo "To use without installing:"
echo "  cd build && LD_LIBRARY_PATH=. ./examples/basic_example"
