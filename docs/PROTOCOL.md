# BitBarrel Network Protocol Specification

## Overview

The BitBarrel network protocol is a binary protocol designed for efficient key-value store operations over WebSocket connections. It provides a compact wire format with minimal overhead while supporting all BitBarrel features including barrel management, key-value operations, and graph traversal.

**Key Features:**
- Binary protocol over WebSocket (RFC 6455 compliant)
- Big-endian encoding for cross-platform compatibility
- Request/response pattern with sequence numbers for correlation
- 11-byte minimum overhead for GET operations
- Support for binary data and UTF-8 strings
- Configurable timeouts and connection management

## Wire Format

### Request Format

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Command Type |                  Sequence                     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      Sequence (continued)                     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|     Key Length (2 bytes)      |          Key Data...          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Key Data...                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Value Length (4 bytes)                     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      Value Length (cont.)                     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Value Data...                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

**Field Descriptions:**

| Field | Size | Description |
|-------|------|-------------|
| Command Type | 1 byte | Operation command (see Command Reference) |
| Sequence | 4 bytes | Monotonically increasing sequence number for request correlation |
| Key Length | 2 bytes | Length of key field in bytes (big-endian uint16) |
| Key | N bytes | Key data (UTF-8 string or binary data) |
| Value Length | 4 bytes | Length of value field in bytes (big-endian uint32) |
| Value | M bytes | Value data (UTF-8 string or binary data) |

**Total size:** 7 + N + M bytes minimum (11 bytes for GET with no value)

### Response Format

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| Status Code   |                  Sequence                     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      Sequence (continued)                     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Value Length (4 bytes)                     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      Value Length (cont.)                     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Value Data...                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

**Field Descriptions:**

| Field | Size | Description |
|-------|------|-------------|
| Status Code | 1 byte | Response status (see Status Codes) |
| Sequence | 4 bytes | Matches the sequence from the request |
| Value Length | 4 bytes | Length of value field in bytes (big-endian uint32) |
| Value | M bytes | Response value or error message |

**Total size:** 5 + M bytes minimum

## Command Reference

### Data Operations

#### GET (0x01)
Retrieve a value by key.

**Request:**
- Command: 0x01
- Key: The key to retrieve
- Value: Empty

**Response:**
- Status: OK (0x00) with value, or NOT_FOUND (0x01)
- Value: The stored value if found

**Example:**
```nim
# Request: GET "user:123"
# Byte representation: [0x01][seq][0x00, 0x08]["user:123"][0x00, 0x00, 0x00, 0x00][]

# Response: OK with value
# Byte representation: [0x00][seq][0x00, 0x00, 0x00, 0x06]["alice"]
```

#### SET (0x02)
Store a key-value pair.

**Request:**
- Command: 0x02
- Key: The key to store
- Value: The value to store

**Response:**
- Status: OK (0x00) on success
- Value: Empty

**Example:**
```nim
# Request: SET "user:123" "alice"
# Byte representation: [0x02][seq][0x00, 0x08]["user:123"][0x00, 0x00, 0x00, 0x05]["alice"]

# Response: OK
# Byte representation: [0x00][seq][0x00, 0x00, 0x00, 0x00][]
```

#### DELETE (0x03)
Delete a key (writes a tombstone).

**Request:**
- Command: 0x03
- Key: The key to delete
- Value: Empty

**Response:**
- Status: OK (0x00) on success
- Value: Empty

#### EXISTS (0x04)
Check if a key exists.

**Request:**
- Command: 0x04
- Key: The key to check
- Value: Empty

**Response:**
- Status: OK (0x00) if exists, NOT_FOUND (0x01) if not
- Value: "true" if exists, "false" if not

#### COUNT (0x05)
Count keys in the current barrel.

**Request:**
- Command: 0x05
- Key: Empty
- Value: Empty

**Response:**
- Status: OK (0x00)
- Value: String representation of count

#### LIST_KEYS (0x06)
List all keys in the current barrel.

**Request:**
- Command: 0x06
- Key: Empty
- Value: Empty

**Response:**
- Status: OK (0x00)
- Value: Comma-separated list of keys

**Note:** Returns all keys; no pagination support.

#### PING (0x09)
Health check / keepalive.

**Request:**
- Command: 0x09
- Key: Empty
- Value: Empty

**Response:**
- Status: OK (0x00)
- Value: "pong"

### Barrel Management

#### CREATE_BARREL (0x10)
Create a new barrel.

**Request:**
- Command: 0x10
- Key: Barrel name
- Value: Optional JSON configuration (currently ignored)

**Response:**
- Status: OK (0x00) on success, BARREL_EXISTS (0x05) if already exists
- Value: Empty

**Example:**
```nim
# Create barrel "mydb"
request = Request(
  command: cmdCreateBarrel,
  key: "mydb",
  value: ""  # JSON config not yet implemented
)
```

#### OPEN_BARREL (0x11)
Open an existing barrel.

**Request:**
- Command: 0x11
- Key: Barrel name
- Value: Empty

**Response:**
- Status: OK (0x00) on success, BARREL_NOT_FOUND (0x06) if not exists
- Value: Empty

#### USE_BARREL (0x12)
Set current barrel for the session.

**Request:**
- Command: 0x12
- Key: Barrel name
- Value: Empty

**Response:**
- Status: OK (0x00) on success, BARREL_NOT_FOUND (0x06) if not exists
- Value: Empty

**Note:** This sets the barrel for subsequent operations in the same WebSocket session.

#### CLOSE_BARREL (0x13)
Close the current barrel.

**Request:**
- Command: 0x13
- Key: Empty
- Value: Empty

**Response:**
- Status: OK (0x00)
- Value: Empty

#### LIST_BARRELS (0x14)
List all available barrels.

**Request:**
- Command: 0x14
- Key: Empty
- Value: Empty

**Response:**
- Status: OK (0x00)
- Value: Comma-separated list of barrel names

#### DROP_BARREL (0x15)
Delete a barrel and all its data.

**Request:**
- Command: 0x15
- Key: Barrel name
- Value: Empty

**Response:**
- Status: OK (0x00) on success, BARREL_NOT_FOUND (0x06) if not exists
- Value: Empty

### Reference Traversal

#### TRAVERSE (0x20) - Advanced Feature
Traverse references from a starting key using path specifications.

**Request Structure:**
```
Request: [cmdTraverse][seq][keyLen][key][encodedTraversalRequest]

where encodedTraversalRequest contains:
[seq:4][startKeyLen:2][startKey][pathSpecLen:2][pathSpec][options:1]
```

**Path Specification:**
- `.` : Current node
- `*` : All references from current node
- `refName` : Specific reference
- `->` : Follow reference(s)
- Examples: `*->*`, `author->books->*`

**Options (bitfield):**
- Bit 0 (0x01): Include full data in results
- Bit 1 (0x02): Extract array elements individually
- Bit 2 (0x04): Return only first result

**Response Format:**
```
Response: [status][seq][count:4][result1][result2]...

Each result contains:
[pathLen:2][path][valueLen:4][value][hasExtracted:1][extractedLen:4][extracted]
```

## Status Codes

| Code | Name | Description |
|------|------|-------------|
| 0x00 | OK | Operation successful |
| 0x01 | NOT_FOUND | Key or resource not found |
| 0x02 | ERROR | Generic error (see value for details) |
| 0x03 | INVALID | Invalid request format or parameters |
| 0x04 | NO_BARREL | No barrel selected for operation |
| 0x05 | BARREL_EXISTS | Barrel already exists |
| 0x06 | BARREL_NOT_FOUND | Barrel does not exist |

## Size Limits

- **Maximum Key Size:** 64 KB (65,535 bytes)
- **Maximum Value Size:** 1 MB (1,048,576 bytes)
- **Maximum Path Length:** 1,024 bytes (for traversal)

## WebSocket Implementation Details

### Frame Structure

The protocol uses WebSocket binary frames (opcode 0x02) with client-to-server masking as required by RFC 6455.

**Frame Format:**
```
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|F|R|R|R| opcode|M| Payload len |
|I|S|S|S|  (4)  |A|     (7)     |
|N|V|V|V|       |S|             |
| |1|2|3|       |K|             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

**Client-to-Server Frames:**
- FIN bit: 1 (final fragment)
- Opcode: 0x02 (binary frame)
- MASK bit: 1 (masked)
- Payload length: Variable (126/127 for extended length)
- Masking key: 4 random bytes
- Payload: XOR-masked protocol data

**Frame Size Limits:**
- Standard frames: Up to 125 bytes payload
- Extended 16-bit: Up to 65,535 bytes payload
- Extended 64-bit: Not supported

## Connection Management

### Handshake

1. Client establishes TCP connection to server
2. Client sends WebSocket upgrade request:
```
GET /ws HTTP/1.1
Host: localhost:9876
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: <base64-random-16-bytes>
Sec-WebSocket-Version: 13
```
3. Server responds with 101 Switching Protocols
4. Connection is established

### Session Management

- Each WebSocket connection maintains a session
- Session tracks current barrel selection
- Sequence numbers are per-connection and monotonic
- Connection loss requires reconnection and barrel reselection

### Timeouts

- **Connection timeout:** 5 seconds (handshake)
- **Operation timeout:** 3 seconds (30 attempts × 100ms)
- **No keepalive:** Client should send PING periodically

## REST API Endpoints

While the binary protocol is primary, BitBarrel also exposes a REST API for simple operations:

```
# Server status
GET /status

# Barrel management
GET    /barrels                    # List all barrels
POST   /barrels                    # Create barrel (auto-named)
GET    /barrels/{name}             # Get barrel info
DELETE /barrels/{name}             # Drop barrel

# Key-value operations
GET    /barrels/{name}/kv/{key}    # Get value
PUT    /barrels/{name}/kv/{key}    # Set value
DELETE /barrels/{name}/kv/{key}    # Delete key
HEAD   /barrels/{name}/kv/{key}    # Check existence
GET    /barrels/{name}/kv          # List keys (query param: ?prefix=)
PUT    /barrels/{name}/kvbatch     # Batch operations (JSON body)

# Graph traversal
GET    /barrels/{name}/traverse/{key}?path=*->*&depth=2
```

## Examples

### Basic Key-Value Operations

```nim
import network/client

var client = newClient("localhost", 9876.Port)
client.connect()

# Create and use a barrel
discard client.createBarrel("mydb")
discard client.useBarrel("mydb")

# Store and retrieve data
discard client.set("key1", "value1")
let value = client.get("key1")  # Returns "value1"

# Check existence
let exists = client.exists("key1")  # Returns true

# Delete
discard client.delete("key1")

client.close()
```

### Graph Traversal

```nim
# Store referenced data
discard client.set("user:alice", "{\"name\":\"Alice\",\"age\":30}")
discard client.set("user:bob", "{\"name\":\"Bob\",\"friend\":\"user:alice\"}")

# Traverse references
let results = client.traversePath("user:bob", "friend->*")
# Returns paths like ["friend->*"]
```

## Error Handling

### Protocol Errors
```nim
try:
  let value = client.get("nonexistent")
except ClientError as e:
  if e.msg.contains("not found"):
    echo "Key does not exist"
  elif e.msg.contains("timeout"):
    echo "Operation timed out"
  else:
    echo "Error: " & e.msg
```

### Connection Errors
```nim
try:
  client.connect()
except ClientError as e:
  echo "Failed to connect: " & e.msg
```

## Performance Characteristics

### Overhead
- GET request: 11 bytes overhead (1+4+2+4)
- GET response: 9 bytes overhead (1+4+4)
- SET request with 10-byte key and 100-byte value: 121 bytes total

### Throughput
- Single connection: ~50,000 ops/sec (local)
- Multiple connections: Linear scaling with CPU cores
- WebSocket framing adds ~4-10 bytes per message

### Latency
- Local operations: < 1ms average
- Network operations: Dependent on latency
- Protocol processing: Negligible (< 0.1ms)

## Security Considerations

- **No encryption:** Protocol is unencrypted; use TLS/WSS in production
- **No authentication:** Server accepts all connections; implement at proxy layer
- **No authorization:** All clients have full access; implement ACLs externally
- **Input validation:** Server validates size limits and protocol format
- **Rate limiting:** Not implemented; use reverse proxy for protection

## Compatibility

### Protocol Version
- Current version: 1.0
- No version negotiation implemented
- Backward compatibility maintained within major versions

### Platform Support
- All platforms supporting WebSocket and TCP
- Big-endian encoding ensures network byte order
- Tested on Linux, macOS, Windows

## Troubleshooting

### Connection Refused
- Check server is running: `nimble server`
- Verify port is correct (default: 9876)
- Check firewall settings

### Timeout Errors
- Server may be overloaded
- Network latency too high
- Increase timeout in client configuration

### Invalid Response
- Check protocol versions match
- Verify data size limits not exceeded
- Review server logs for errors

### Barrel Not Found
- Create barrel before use
- Check barrel name spelling
- Verify barrel was not dropped

## Future Enhancements

- Protocol versioning for backward compatibility
- Request pipelining for higher throughput
- Connection pooling in client
- Automatic reconnection with backoff
- Compression for large values
- Bulk operations (multi-get, multi-set)
- Pub/sub notifications
- Streaming responses for large queries
