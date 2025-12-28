# BitBarrel Network Protocol Implementation

## Overview

The network protocol layer for BitBarrel provides remote access via WebSocket binary protocol and REST API, built on MummyX.

## Components

### Binary Protocol (`src/network/protocol.nim`)
- Request/Response message structures
- Commands (19 total):
  - Data: GET, SET, DELETE, EXISTS, COUNT, LIST_KEYS, PING
  - Barrel: CREATE_BARREL, OPEN_BARREL, USE_BARREL, CLOSE_BARREL, LIST_BARRELS, DROP_BARREL
  - Config: GET_BARREL_CONFIG, SET_BARREL_CONFIG
  - Query: TRAVERSE, RANGE_QUERY, PREFIX_QUERY, RANGE_COUNT
- Status codes: OK, NOT_FOUND, ERROR, INVALID, NO_BARREL, BARREL_EXISTS, BARREL_NOT_FOUND
- Big-endian encoding for cross-platform compatibility
- Size limits: 64KB max key, 32MB max value

### Session & Barrel Registry (`src/network/session.nim`)
- Session management per WebSocket connection
- Thread-safe BarrelRegistry with Lock-protected operations
- Support for multiple concurrent barrels per server
- Per-session current barrel tracking

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

### Feature Matrix

| Feature | Nim | Go | Dart/Flutter | Python |
|---------|-----|----|--------------|--------|
| WebSocket protocol | ✅ | ✅ | ✅ | ✅ |
| CRUD operations | ✅ | ✅ | ✅ | ✅ |
| Barrel management | ✅ | ✅ | ✅ | ✅ |
| Range queries | ✅ | ✅ | ✅ | ✅ |
| Prefix queries | ✅ | ✅ | ✅ | - |
| Reference traversal | ✅ | ✅ | ✅ | - |
| Cursor pagination | ✅ | ✅ | ✅ | - |
| Thread-safe | ✅ | ✅ | ✅ | ✅ |
| Mobile support | - | - | ✅ | - |
| Web support | - | - | ✅ | - |

**Dart/Flutter Client**: Uses web_socket_channel for cross-platform compatibility. Includes comprehensive API for all 19 protocol commands, cursor-based pagination for efficient large dataset operations, and works on both mobile (iOS/Android) and Flutter Web.

**Go Client**: Full-featured client with examples for basic operations, barrel management, and concurrent access patterns.

**Nim Client**: Standalone nimble package with full feature parity with the server.

**Python Client**: WebSocket-based client with basic CRUD and barrel operations.

### Testing All Clients

```bash
# Test all client libraries (starts server on port 9876, runs tests, stops server)
nimble testClients
```

## Protocol Format

### Standard Request/Response
```
Request:  [cmd:1][seq:4][keyLen:2][key:N][valLen:4][value:M]
Response: [status:1][seq:4][valLen:4][value:M]
```

Compact overhead: 11 bytes for GET requests (no value).

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

let config = ServerConfig(
  address: "0.0.0.0",
  port: 9876.Port,
  dataDir: "./data"
)
var server = newServer(config)
server.start()
```

### Nim Client
```nim
import network/client

var client = newClient("localhost", 9876.Port)
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

import "github.com/tankfeed/bitbarrel-go"

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
4. **Concurrent requests**: Client operations are serialized (no request pipelining)
5. **Configuration**: JSON config parsing for CREATE_BARREL not yet implemented
6. **Pagination**: LIST_KEYS returns all keys (no pagination support)

## Architecture Notes

- Server uses MummyX's TaskPools for concurrent request handling
- Each WebSocket connection has its own session with current barrel tracking
- BarrelRegistry provides thread-safe barrel lifecycle management
- No CRC32 in protocol (TCP/WebSocket provides integrity)

## Testing

Protocol tests: `tests/test_protocol.nim`
Session tests: `tests/test_session.nim`
Client integration tests: `tests/network/`

## Future Work

- Connection pooling in client
- Protocol versioning for backwards compatibility
- Async client operations
- Reconnection with exponential backoff
- Request pipelining
