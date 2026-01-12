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

## Client Libraries

BitBarrel provides client libraries for multiple languages:

| Language | Location | Status |
|----------|----------|--------|
| Nim | `clients/nim/` | Full WebSocket protocol, Pub/Sub (Phase 2 complete) |
| Go | `clients/go/` | Full WebSocket protocol, Pub/Sub (basic subscribe/publish) |
| Dart/Flutter | `clients/dart/` | Mobile + Web compatible |
| Python | `clients/python/` | Feature-complete WebSocket client, Pub/Sub (full implementation) |
| TypeScript | `clients/typescript/` | Full WebSocket protocol + types, Pub/Sub (full implementation) |

**Pub/Sub Messaging**: BitBarrel includes real-time Pub/Sub messaging with topic-based subscriptions, pattern matching, and presence tracking. See [Pub/Sub Protocol Specification](../PROTOCOL.md#pubsub-messaging) for details.

### Quick Start - Dart/Flutter

```bash
cd clients/dart
dart pub get
dart run example/basic_example.dart
```

### Quick Start - Go

```bash
cd clients/go
go run examples/basic/main.go
```

### Quick Start - Web Admin Console

BitBarrel includes a modern web-based admin console for visual database management. The webadmin can be served directly from the BitBarrel server (recommended for Docker) or run separately during development.

**Option 1: Server-Integrated Webadmin (Recommended for Docker)**

```bash
# Build webadmin first
cd webadmin
flutter build web --release
cd ..

# Start BitBarrel with integrated webadmin
./bitbarrel serve --webadmin-path=./webadmin/build/web

# Access at http://localhost:8080/admin/
```

**Option 2: Separate Development Server**

```bash
# Start the BitBarrel server first
./bitbarrel serve

# In another terminal, start the web admin
cd webadmin
flutter pub get
flutter run -d chrome --web-port 8080

# Open http://localhost:8080 in your browser
```

The web admin provides:
- Visual connection management with JWT authentication
- Barrel management UI (create, delete, switch)
- Data explorer with full CRUD operations
- Query interface for prefix and range queries
- JSON visualization with syntax highlighting

See [webadmin/README.md](../webadmin/README.md) for detailed documentation.

### Automatic Barrel Discovery

When starting the BitBarrel server, it automatically discovers existing barrels in the data directory:

- **Regular barrels** (`.data` files) are detected and made available
- **HugeBarrels** (directories with `barrel1/` and `barrel2/` subdirectories) are automatically recognized
- **YAML configuration files** are created automatically for discovered barrels (if they don't exist)
- **Lazy loading** - barrels are tracked but not opened until first access

Example server startup output:
```
[BarrelRegistry] Discovering barrels in './data'
[BarrelRegistry] Creating YAML config for 'users'
[BarrelRegistry] Discovered regular barrel 'users'
[BarrelRegistry] Discovered HugeBarrel 'analytics'
[BarrelRegistry] Discovery complete: 2 barrels found, 1 YAML configs created
BitBarrel discovery: 2 barrels available, 1 configs created
```

To list all available barrels from a client:
```nim
# Using the network client
let client = newNetworkClient("localhost", 9876)
let barrels = client.listBarrels()
echo "Available barrels: ", barrels
```

### Testing All Clients

```bash
# Test all client libraries (starts server on port 9876, runs tests, stops server)
nimble testClients
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
- [Client Libraries](../clients/) - Nim, Go, Dart/Flutter, Python clients

## Need Help?

- Run tests: `nimble test`
- Check architecture: [DEVELOPER_GUIDE/architecture.md](DEVELOPER_GUIDE/architecture.md)
- View demos: `demos/` directory