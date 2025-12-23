# Getting Started with BitBarrel

Quick setup guide to get BitBarrel running in 5 minutes.

## Prerequisites

- Nim >= 2.0 installed
- Basic understanding of key-value stores

## Installation

```bash
# Clone the repository
git clone https://github.com/your-repo/bitbarrel.git
cd bitbarrel

# Install dependencies
nimble install

# Build the project
nimble build
```

## Quick Test

Run a simple demo to verify installation:

```bash
# Basic CRUD demo
nimble demoBasic

# Result: Should show key creation, retrieval, and deletion ✓
```

## Your First BitBarrel

```nim.compilable
import bitbarrel

# Open a key-value store
var barrel = openBarrel("mydata.db", defaultBarrelConfig())

# Write data
discard barrel.set("name", "BitBarrel")
discard barrel.set("version", "1.0")

# Read data
echo barrel.get("name")
echo barrel.get("version")

# Check existence
if barrel.exists("name"):
  echo "Key found!"

# Delete
discard barrel.delete("name")

# Close
barrel.close()
```

## Running Benchmarks

```bash
# Quick benchmark (1K operations)
nimble benchQuick

# Full benchmark suite
nimble bench
```

## Next Steps

- [User Guide](USER_GUIDE/tutorial.md) - Comprehensive tutorial
- [Configuration](USER_GUIDE/configuration.md) - All options
- [API Reference](USER_GUIDE/api-reference.md) - Full API
- [Features](FEATURES/) - Compression, networking, data integrity

## Need Help?

- Run tests: `nimble test`
- Check architecture: [DEVELOPER_GUIDE/architecture.md](DEVELOPER_GUIDE/architecture.md)
- View examples: `examples/` directory