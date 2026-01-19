# BitBarrel Network Protocol Implementation

## Overview

The network protocol layer for BitBarrel provides remote access via WebSocket binary protocol and REST API, built on MummyX.

## Components

### Binary Protocol (`src/network/protocol.nim`)
- Request/Response message structures with v1.1 protocol enhancements
- Commands (28 total):
  - Data: GET, SET, DELETE, EXISTS, COUNT, LIST_KEYS, PING (7)
  - Barrel: CREATE_BARREL, OPEN_BARREL, USE_BARREL, CLOSE_BARREL, LIST_BARRELS, DROP_BARREL (6)
    - Note: Discovered barrels are lazy-loaded automatically, OPEN_BARREL optional
  - Config: GET_BARREL_CONFIG, SET_BARREL_CONFIG (2)
  - Query: TRAVERSE, RANGE_QUERY, PREFIX_QUERY, RANGE_COUNT, RANGE_KEYS, PREFIX_KEYS (6)
  - Key Watches: WATCH_KEY (0x60), UNWATCH_KEY (0x61) (2)
  - Pub/Sub: SUBSCRIBE, UNSUBSCRIBE, PUBLISH, HISTORY, LIST_SUBSCRIBERS, PRESENCE, LIST_TOPICS (7)
- Status codes: OK, NOT_FOUND, ERROR, INVALID, NO_BARREL, BARREL_EXISTS, BARREL_NOT_FOUND, UNAUTHORIZED
- Big-endian encoding for cross-platform compatibility
- Size limits: 64KB max key, 32MB max value
- Protocol v1.1 features:
  - Binary handshake with version negotiation, serverId (UUID), and hook discovery
  - Request flags byte (rfNone, rfHasTtl) for protocol extensions
  - Per-key TTL support in SET command
  - Client-side request pipelining for reduced latency

### Session & Barrel Registry (`src/network/session.nim`)
- Session management per WebSocket connection
- Thread-safe BarrelRegistry with Lock-protected operations
- Support for multiple concurrent barrels per server
- Per-session current barrel tracking
- Automatic barrel discovery on server startup
- Lazy loading of discovered barrels via `getBarrel()`
- YAML configuration auto-generation for discovered barrels

### Network Server (`src/network/server.nim`)
- Built on MummyX with TaskPools execution model
- WebSocket binary protocol handler with proper frame handling
- REST API endpoints for barrel management
- Thread-safe session and counter access
- Proper URL percent-decoding

### Network Client (`src/network/client.nim`)
- WebSocket client with RFC 6455 compliant framing
- Client-to-server masking (required by spec)
- Synchronous API with timeout handling
- Auto-connect on first operation

## Client Libraries

BitBarrel provides client libraries in multiple languages:

| Library | Location | Platform Support |
|---------|----------|------------------|
| Nim | `clients/nim/` | Cross-platform |
| Go | `clients/go/` | Cross-platform |
| Dart/Flutter | `clients/dart/` | Android, iOS, Web |
| Python | `clients/python/` | Cross-platform |
| TypeScript | `clients/typescript/` | Node.js, Browser |
| **C** | `clients/c/` | Cross-platform |
| **Zig** | `clients/zig/` | Cross-platform |

### Feature Matrix

| Feature | Nim | Go | Dart/Flutter | Python | TypeScript | **C** | **Zig** |
|---------|-----|----|--------------|--------|------------|-------|---------|
| WebSocket protocol | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| CRUD operations | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Barrel management | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Barrel config ops | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Range queries | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Prefix queries | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Reference traversal | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| Cursor pagination | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| JWT authentication | ✅ | ✅ | ✅ | ✅ | ✅ | N/A | N/A |
| GetOrDefault method | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Context manager | ✅ | - | - | ✅ | - | - | - |
| Thread-safe | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| TypeScript types | - | - | - | - | ✅ | - | - |
| Memory-safe bindings | - | - | - | - | - | - | ✅ |
| Mobile support | - | - | ✅ | - | - | - | - |
| Web support | - | - | ✅ | - | ✅ | - | - |
| Build system | nimble | go mod | pub | pip/setuptools | npm | CMake | zig build |

**Dart/Flutter Client**: Uses web_socket_channel for cross-platform compatibility. Includes comprehensive API for all 19 protocol commands, cursor-based pagination for efficient large dataset operations, and works on both mobile (iOS/Android) and Flutter Web.

**Go Client**: Full-featured client with examples for basic operations, barrel management, and concurrent access patterns.

**Nim Client**: Standalone nimble package with full feature parity with the server.

**Python Client**: Feature-complete WebSocket client with support for all protocol commands including barrel config operations, range queries, prefix queries, reference traversal, and context manager support.

**TypeScript Client**: Full WebSocket protocol implementation with complete type safety. Provides TypeScript interfaces for all API methods, automatic connection management with configurable timeouts, EventEmitter-based architecture for connection events, comprehensive error hierarchy, and full support for range queries, barrel management, and JWT authentication. Includes 57 passing tests and extensive documentation.

**C Client**: Full WebSocket protocol (v1.1) implementation with binary protocol encoding/decoding. Provides a C99-compatible API with explicit resource management, thread-safe operations, Pub/Sub support, range queries, and memory management utilities. Native implementation with CMake build system.

**Zig Bindings**: Idiomatic Zig API wrapping the C client library with memory safety features. Provides Zig-style error handling, allocator integration, and comptime configuration. Memory-safe bindings with idiomatic Zig patterns and build.zig build integration.

**Web Admin Console**: Flutter-based web UI for visual database management. Can be served directly from the BitBarrel server at `/admin/` or run separately during development. Provides connection management, barrel operations, data explorer with full CRUD, query interface with JSON visualization, graph traversal for exploring _ref relationships, and barrel configuration editor for runtime tuning. See [webadmin/README.md](../../webadmin/README.md) and [Getting Started](../GETTING_STARTED.md#quick-start---web-admin-console) for details.

### Testing All Clients

```bash
# Test all client libraries (starts server on port 9876, runs tests, stops server)
nimble testClients
```

## Protocol Format

### Standard Request/Response (v1.1)
```
Request:  [cmd:1][seq:4][flags:1][keyLen:2][key:N][valLen:4][value:M][ttl:4|optional]
Response: [status:1][seq:4][valLen:4][value:M]
```

**Request flags (v1.1):**
- rfNone (0x00): No special flags
- rfHasTtl (0x01): TTL field present after value (for SET command)

**Binary Handshake (v1.1):**
Server sends immediately after WebSocket connection:
```
[versionMajor:1][versionMinor:1][serverIdLen:2][serverId:N][hookCount:1][hookNameLen1:2][hookName1]...
```

**Watch Key Request (0x60):**
```
[barrelNameLen:2][barrelName][patternLen:2][pattern][options:1]
```

Compact overhead: 12 bytes for GET requests (no value) in v1.1.

### v1.0 Compatibility
v1.0 format (without flags byte) is still supported. Servers automatically decode both formats.

### Range Query Request (encoded in value field)
```
[startKeyLen:2][startKey][endKeyLen:2][endKey][limit:4][cursorLen:2][cursor]
```

### Prefix Query Request (encoded in value field)
```
[prefixLen:2][prefix][limit:4][cursorLen:2][cursor]
```

### Range/Prefix Query Response (in value field)
```
[count:4][items...][hasMore:1][nextCursorLen:2][nextCursor]
Each item: [keyLen:2][key][valLen:4][value]
```

## REST API

```
GET  /status                          # Server health and stats
GET  /barrels                         # List all barrels
POST /barrels                         # Create barrel (auto-named)
GET  /barrels/{name}                  # Get barrel info
DELETE /barrels/{name}                # Drop barrel
GET    /barrels/{name}/kv/{key}       # Get value
PUT    /barrels/{name}/kv/{key}       # Set value
DELETE /barrels/{name}/kv/{key}       # Delete key
HEAD   /barrels/{name}/kv/{key}       # Check if key exists
```

## Usage

### Server
```nim
import network/server
import network/auth as authjwt

let config = ServerConfig(
  address: "0.0.0.0",
  port: 9876.Port,
  dataDir: "./data",
  auth: authjwt.AuthConfig(
    enabled: true,
    secret: "production-secret-key-32-chars-minimum",
    users: {
      "admin": @[authjwt.rAdmin],
      "app": @[authjwt.rReadWrite],
      "readonly": @[authjwt.rReadonly]
    }.toTable()
  )
)
var server = newServer(config)
server.start()
```

### Nim Client
```nim
import network/client

var client = newClient(
  host = "localhost",
  port = 9876.Port,
  token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
)
client.connect()

# Barrel operations
discard client.createBarrel("mydb")
discard client.useBarrel("mydb")

# Key-value operations
discard client.set("key", "value")
let value = client.get("key")
discard client.delete("key")

client.close()
```

### Dart Client
```dart
import 'package:bitbarrel/bitbarrel.dart';

final client = BitBarrelClient.localhost();
await client.connect();
await client.createBarrel('mydb');
await client.useBarrel('mydb');
await client.set('key', 'value');
final value = await client.get('key');
await client.close();
```

### Go Client
```go
package main

import "github.com/gokr/bitbarrel-go"

client := bitbarrel.NewClient("localhost", 9876)
client.Connect()
client.CreateBarrel("mydb", "")
client.UseBarrel("mydb")
client.Set("key", "value")
value := client.Get("key")
client.Close()
```

## Known Limitations

1. **Client timeout**: Fixed 3-second timeout on all operations (30 attempts × 100ms polling)
2. **No reconnection**: Client does not auto-reconnect on connection loss
3. **Large frames**: 64-bit WebSocket frame lengths not supported
4. **CREATE_BARREL config**: JSON config for CREATE_BARREL creates with defaults (use SET_BARREL_CONFIG after)
5. **LIST_KEYS**: Returns all keys without pagination (use RANGE_KEYS or PREFIX_KEYS with cursor pagination for large datasets)
6. **Token refresh**: JWT tokens don't auto-refresh; clients must handle token expiry
7. **Token storage**: JWT secret must be stored securely; lost secret invalidates all tokens
8. **Client-side pipelining**: Request pipelining is implemented client-side (see Pipeline API) for batching operations

## Architecture Notes

- Server uses MummyX's TaskPools for concurrent request handling
- Each WebSocket connection has its own session with current barrel tracking and authentication state
- BarrelRegistry provides thread-safe barrel lifecycle management
- Server verifies JWT tokens in WebSocket upgrade handler using HS256 signature
- Authorization checks are performed per-command based on user roles (admin, readwrite, readonly) before execution
- No CRC32 in protocol (TCP/WebSocket provides integrity)

## Testing

Protocol tests: `tests/test_protocol.nim`
Session tests: `tests/test_session.nim`
Client integration tests: `tests/network/`

## Future Work

- Connection pooling in client
- Async client operations
- Reconnection with exponential backoff
- Client library support for v1.1 features (WATCH_KEY, pipelining, TTL)
