# BitBarrel Client for Nim

A WebSocket client library for connecting to BitBarrel key-value store servers.

## Installation

```bash
nimble install bitbarrel_client
```

Or add to your `.nimble` file:

```nim
requires "bitbarrel_client >= 0.1.0"
```

## Quick Start

```nim
import bitbarrel_client

var client = newClient("localhost", 9876.Port)
client.connect()

# Create and use a barrel
discard client.createBarrel("mydb")
discard client.useBarrel("mydb")

# Store and retrieve data
discard client.set("key", "value")
echo client.get("key")  # "value"

# Check existence
echo client.exists("key")  # true

# Delete
discard client.delete("key")

# Cleanup
discard client.dropBarrel("mydb")
client.close()
```

## Features

- Binary protocol over WebSocket for efficient communication
- Barrel management (create, open, use, close, drop, list)
- Key-value operations (get, set, delete, exists, count, listKeys)
- Range queries and prefix searches (requires bmCritBit mode barrel)
- Reference traversal for graph-like data
- Thread-safe request handling

## API Reference

### Client Creation

```nim
# Create with defaults (localhost:9876)
var client = newClient()

# Create with custom host/port
var client = newClient("192.168.1.100", 8080.Port)

# Create with full config
let config = ClientConfig(
  host: "localhost",
  port: 9876.Port,
  connectTimeout: 5000,
  requestTimeout: 3000
)
var client = newClient(config)
```

### Connection Management

```nim
client.connect()        # Connect to server
client.close()          # Close connection
client.ping()           # Check connectivity (returns bool)
client.isConnected      # Check connection status
```

### Barrel Operations

```nim
client.createBarrel("mydb")         # Create new barrel
client.createBarrel("mydb", config) # Create with JSON config
client.openBarrel("mydb")           # Open existing barrel
client.useBarrel("mydb")            # Select barrel for operations
client.closeBarrel()                # Close current barrel
client.dropBarrel("mydb")           # Delete barrel and data
client.listBarrels()                # List all barrels
```

### Key-Value Operations

```nim
client.set("key", "value")              # Store value
client.get("key")                       # Get value (raises if not found)
client.getOrDefault("key", "default")   # Get with default
client.delete("key")                    # Delete key
client.exists("key")                    # Check if key exists
client.count()                          # Count keys in barrel
client.listKeys()                       # List all keys
```

### Range Queries (bmCritBit mode)

```nim
# Range query with pagination
let (items, nextCursor, hasMore) = client.rangeQuery("a", "z", limit=100)

# Prefix query
let (items, nextCursor, hasMore) = client.prefixQuery("user:", limit=100)

# Count keys in range
let count = client.rangeCount("user:0", "user:999")
```

### Reference Traversal

```nim
let options = TraverseOptions(
  includeFullData: true,
  extractArrays: false,
  firstOnly: false
)
let results = client.traverse("user:1", "->friend", options)

# Or with defaults
let results = client.traversePath("user:1", "->friend")
```

## Error Handling

All operations that can fail raise `ClientError`:

```nim
try:
  let value = client.get("missing_key")
except ClientError as e:
  echo "Error: ", e.msg
```

Use `getOrDefault` to avoid exceptions for missing keys:

```nim
let value = client.getOrDefault("missing", "default_value")
```

## Running Tests

```bash
# Unit tests (no server needed)
nimble test

# Integration tests (requires running server)
nimble testIntegration
```

## Keeping Protocol in Sync

The protocol definition is shared with the server. To update:

```bash
nimble syncProtocol
```

This copies `protocol.nim` from the main BitBarrel source.

## Examples

See the `examples/` directory:

- `basic_usage.nim` - Basic CRUD operations
- `error_handling.nim` - Error handling patterns

Run examples:

```bash
nim c -r examples/basic_usage.nim
```

## Requirements

- Nim >= 2.0.0
- whisky (WebSocket library)
- Running BitBarrel server for integration tests

## License

MIT
