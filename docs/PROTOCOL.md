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

Barrels discovered during server startup are lazy-loaded automatically on first access via `getBarrel()`. This command can be used to explicitly open a barrel or verify it exists.

**Request:**
- Command: 0x11
- Key: Barrel name
- Value: Empty

**Response:**
- Status: OK (0x00) on success, BARREL_NOT_FOUND (0x06) if not exists
- Value: Empty

**Note:** REST API clients typically don't need to call OPEN_BARREL for discovered barrels, as they are opened automatically on first access.

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

### Configuration Operations

#### GET_BARREL_CONFIG (0x16)
Get the configuration of a barrel.

**Request:**
- Command: 0x16
- Key: Barrel name
- Value: Empty

**Response:**
- Status: OK (0x00) with configuration JSON, BARREL_NOT_FOUND (0x06) if not exists
- Value: JSON object containing barrel configuration

**Example Response:**
```json
{
  "writeBufferSize": 65536,
  "syncMode": "sync",
  "autoCompact": false,
  "compactThreshold": 0.3,
  "validateCrc": true,
  "defaultTtl": 0,
  "checkExpirationOnRead": true,
  "deleteExpiredOnRead": false,
  "mode": "hash"
}
```

#### SET_BARREL_CONFIG (0x17)
Update the configuration of a barrel. Changes are persisted to a YAML file alongside the data file.

**Request:**
- Command: 0x17
- Key: Barrel name
- Value: JSON object with configuration fields to update (partial update supported)

**Response:**
- Status: OK (0x00) with updated configuration JSON
- Status: ERROR (0x02) if mode change attempted (not allowed at runtime)
- Status: BARREL_NOT_FOUND (0x06) if barrel not exists
- Status: UNAUTHORIZED (0x07) if insufficient permissions (requires admin role)

**Example Request:**
```json
{
  "autoCompact": true,
  "compactThreshold": 0.5
}
```

**Configurable Fields:**
| Field | Type | Description |
|-------|------|-------------|
| writeBufferSize | int | Write buffer size in bytes (default: 65536) |
| syncMode | string | "none", "sync", or "fsync" |
| autoCompact | bool | Enable automatic compaction |
| compactThreshold | float | Compaction trigger threshold (0.0-1.0) |
| validateCrc | bool | Validate CRC32 on reads |
| defaultTtl | int | Default TTL in seconds (0 = no expiration) |
| checkExpirationOnRead | bool | Check expiration when reading |
| deleteExpiredOnRead | bool | Delete expired records on read |

**Note:** The `mode` field cannot be changed at runtime as it requires rebuilding the entire index structure.

#### GET_BARREL_STATS (0x18)
Get statistics for a barrel.

**Request:**
- Command: 0x18
- Key: Barrel name
- Value: Empty

**Response:**
- Status: OK (0x00) with statistics JSON, BARREL_NOT_FOUND (0x06) if not exists
- Value: JSON object containing barrel statistics

**Example Response:**
```json
{
  "keyCount": 12345,
  "totalKeys": 12500,
  "deletedKeys": 150,
  "fileCount": 3,
  "totalSize": 5242880,
  "fragmentationRatio": 0.15,
  "oldestTimestamp": 1734800000,
  "newestTimestamp": 1734806400,
  "compactionInProgress": false
}
```

### Range Queries

Range queries require the barrel to be opened in `bmCritBit` mode (ordered index).

#### RANGE_QUERY (0x21)
Get key-value pairs in a key range.

**Request:**
- Command: 0x21
- Key: Empty
- Value: Encoded range request

**Range Request Format:**
```
[startKeyLen:2][startKey][endKeyLen:2][endKey][limit:4][cursorLen:2][cursor]
```

**Response:**
- Status: OK (0x00) with encoded range response
- Status: ERROR (0x02) if barrel not in bmCritBit mode

**Range Response Format:**
```
[count:4][items...][hasMore:1][nextCursorLen:2][nextCursor]

Each item:
[keyLen:2][key][valueLen:4][value]
```

#### PREFIX_QUERY (0x22)
Get key-value pairs with a key prefix.

**Request:**
- Command: 0x22
- Key: Empty
- Value: Encoded prefix request

**Prefix Request Format:**
```
[prefixLen:2][prefix][limit:4][cursorLen:2][cursor]
```

**Response:**
- Same format as RANGE_QUERY response

#### RANGE_COUNT (0x23)
Count keys in a range without retrieving values.

**Request:**
- Command: 0x23
- Key: Empty
- Value: Encoded range request (same as RANGE_QUERY)

**Response:**
- Status: OK (0x00)
- Value: String representation of count

#### RANGE_KEYS (0x24)
Get only keys in a range (values omitted). More efficient than RANGE_QUERY when values aren't needed.

**Request:**
- Command: 0x24
- Key: Empty
- Value: Encoded range request (same format as RANGE_QUERY)

**Response:**
- Status: OK (0x00) with encoded keys response
- Status: ERROR (0x02) if barrel not in bmCritBit mode

**Keys Response Format:**
```
[count:4][keys...][hasMore:1][nextCursorLen:2][nextCursor]

Each key:
[keyLen:2][key]
```

#### PREFIX_KEYS (0x25)
Get only keys with a prefix (values omitted). More efficient than PREFIX_QUERY when values aren't needed.

**Request:**
- Command: 0x25
- Key: Empty
- Value: Encoded prefix request (same format as PREFIX_QUERY)

**Response:**
- Same format as RANGE_KEYS response

### Pub/Sub Messaging

Pub/Sub commands enable real-time messaging with topic-based subscriptions. WebSocket clients receive push notifications for published messages. For complete documentation including topic patterns, message types, and client examples, see the [Pub/Sub User Guide](./USER_GUIDE/pubsub.md).

#### SUBSCRIBE (0x40)
Subscribe to a topic to receive published messages.

**Request:**
- Command: 0x40
- Key: Topic name
- Value: JSON options (optional, for subscription configuration)

**Subscription Options:**
```json
{
  "enableKvEvents": false
}
```

**Response:**
- Status: OK (0x00) on success
- Value: Empty

**Note:** Subscribed clients will receive push messages when other clients publish to this topic.

#### UNSUBSCRIBE (0x41)
Unsubscribe from a topic.

**Request:**
- Command: 0x41
- Key: Topic name
- Value: Empty

**Response:**
- Status: OK (0x00) on success
- Status: ERROR (0x02) if not subscribed
- Value: Empty

#### PUBLISH (0x42)
Publish a message to a topic.

**Request:**
- Command: 0x42
- Key: Topic name
- Value: Payload string (JSON, text, or binary data)

**Response:**
- Status: OK (0x00) on success
- Value: Empty

**Note:** All subscribed WebSocket clients receive the published message as a push event.

#### LIST_SUBSCRIBERS (0x43)
List all subscribers for a topic.

**Request:**
- Command: 0x43
- Key: Topic name
- Value: Empty

**Response:**
- Status: OK (0x00) with subscribers JSON
- Value: JSON array of subscriber info

**Example Response:**
```json
[
  {
    "id": "sub123",
    "clientId": "client456",
    "topic": "chat:general",
    "joinedAt": 1734800000,
    "lastPing": 1734800600
  }
]
```

#### HISTORY (0x44)
Get message history for a topic.

**Request:**
- Command: 0x44
- Key: Topic name
- Value: JSON options for query

**History Options:**
```json
{
  "limit": 100,
  "offset": 0
}
```

**Response:**
- Status: OK (0x00) with history JSON
- Value: JSON array of messages with metadata

**Example Response:**
```json
[
  {
    "topic": "chat:general",
    "sequence": 123,
    "messageType": 0,
    "timestamp": 1734800000,
    "headers": "{}",
    "payload": "Hello, world!"
  }
]
```

#### LIST_TOPICS (0x45)
List all available topics.

**Request:**
- Command: 0x45
- Key: Empty
- Value: Empty

**Response:**
- Status: OK (0x00)
- Value: JSON array of topic names

**Example Response:**
```json
["chat:general", "chat:private", "metrics:cpu"]
```

#### PRESENCE (0x46)
Get presence information for a topic (online subscribers).

**Request:**
- Command: 0x46
- Key: Topic name
- Value: Empty

**Response:**
- Status: OK (0x00) with presence JSON
- Value: JSON object with member list

**Example Response:**
```json
{
  "topic": "chat:general",
  "members": [
    {
      "clientId": "client123",
      "joinedAt": 1734800000,
      "lastPing": 1734800600,
      "metadata": "{\"username\":\"alice\"}"
    }
  ],
  "lastUpdate": 1734800600
}
```

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
| 0x07 | UNAUTHORIZED | Authentication failed or insufficient permissions |

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
2. Client sends WebSocket upgrade request with optional JWT authentication:
```
GET /ws HTTP/1.1
Host: localhost:9876
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: <base64-random-16-bytes>
Sec-WebSocket-Version: 13
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

**Authorization Header:**
- Required if server authentication is enabled
- Format: `Authorization: Bearer <jwt_token>`
- JWT tokens are generated using `bitbarrel token` CLI command
- Server verifies HS256 signature and extracts username/roles

3. Server responds:
   - `101 Switching Protocols` if auth successful or auth disabled
   - `401 Unauthorized` if auth required but missing/invalid
4. Connection is established

### Session Management

- Each WebSocket connection maintains a session
- Session tracks current barrel selection and authentication state
- Sequence numbers are per-connection and monotonic
- Connection loss requires reconnection and barrel reselection
- Authenticated sessions include username and roles for authorization

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

**Authentication (when enabled):**
```
Authorization: Bearer <jwt_token>
```

All authenticated REST requests must include the JWT bearer token in the Authorization header.

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

- **Encryption:** Protocol is unencrypted; use TLS/WSS in production
- **JWT Authentication:** Server supports HS256 JWT tokens with RBAC (admin, readwrite, readonly roles)
- **Authorization:** Commands are checked against user role permissions
- **Input validation:** Server validates size limits and protocol format
- **Rate limiting:** Not implemented; use reverse proxy for production

### JWT Authentication Details

- **Algorithm:** HS256 (HMAC SHA-256)
- **Token generation:** Use `bitbarrel token` CLI command
- **Token format:** `Authorization: Bearer <base64-encoded-jwt>`
- **Token claims:** `sub` (username), `roles` (array), `iat` (issued), `exp` (expiry)
- **Default expiry:** 24 hours (configurable)

### JWT vs External Auth

| Aspect | JWT (Internal) | External Proxy |
|--------|----------------|---------------|
| Configuration | Single secret in YAML | TLS cert management, separate auth service |
| Token storage | Environment var or config | TLS client certificates or OIDC |
| Permission checks | Server-side RBAC | Proxy rules (nginx ACLs) |
| Token rotation | Secret rotation + new tokens | Certificate renewal, OIDC token refresh |
| Complexity | Simple, self-contained | More components, distributed coordination |

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
- Barrels are automatically discovered on server startup from the data directory
- Check barrel name spelling
- Verify barrel data files exist in the configured data directory
- YAML configs are auto-created for discovered barrels
- Use LIST_BARRELS to see all available barrels
- Create new barrel with CREATE_BARREL if needed

## Future Enhancements

- Protocol versioning for backward compatibility
- Request pipelining for higher throughput
- Connection pooling in client
- Automatic reconnection with backoff
- Compression for large values
- Bulk operations (multi-get, multi-set)
- Streaming responses for large queries
