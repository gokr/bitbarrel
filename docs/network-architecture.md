# BitBarrel Network Architecture

This document describes the architecture of BitBarrel's network protocol implementation, including the client-server model, session management, and threading model.

## Overview

BitBarrel's network layer provides remote access to the embedded key-value store through:
- **Binary Protocol:** Efficient WebSocket-based protocol for key-value operations
- **Pub/Sub Messaging:** Real-time topic-based publish/subscribe with pattern matching
- **REST API:** HTTP endpoints for simple operations and integration
- **Session Management:** Per-connection barrel state and isolation
- **Thread Safety:** Lock-protected data structures for concurrent access

## System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Client Applications                      │
├─────────────────────────────────────────────────────────────┤
│  Nim Client    │    Go Client    │    Other Languages       │
│   Library      │    Library      │    (via WebSocket)       │
├─────────────────────────────────────────────────────────────┤
│           WebSocket Protocol (RFC 6455)                     │
│              Binary Frames with Masking                     │
├─────────────────────────────────────────────────────────────┤
│                BitBarrel Network Server                     │
│              (MummyX + TaskPools Threading)                 │
├──────────────┬──────────────┬──────────────┬────────────────┤
│   Protocol   │   Session    │   Pub/Sub    │    REST API    │
│   Handler    │  Manager     │    System    │   Endpoints    │
├──────────────┴──────────────┴──────────────┴────────────────┤
│                 Barrel Registry (Thread-Safe)               │
├─────────────────────────────────────────────────────────────┤
│               BitBarrel Storage Engine                      │
│           (KeyDir + Data Files + Compaction)                │
└─────────────────────────────────────────────────────────────┘
```

## Component Architecture

### 1. Network Client (`src/network/client.nim`)

**Responsibilities:**
- WebSocket connection management
- Protocol encoding/decoding
- Request/response correlation
- Connection state management

**Key Features:**
- Auto-connect on first operation
- Fixed 3-second operation timeout
- Sequence number tracking
- Barrel session tracking

**Threading Model:**
- Single connection per client instance
- Synchronous API (blocks until response)
- Lock-protected pending response table

**Limitations:**
- No connection pooling
- No automatic reconnection
- Operations serialized per client

### 2. Network Server (`src/network/server.nim`)

**Responsibilities:**
- WebSocket handshake handling
- HTTP request routing
- Protocol message dispatch
- Session lifecycle management

**Threading Model:**
- MummyX web server with TaskPools
- Per-connection session isolation
- Thread-safe barrel registry
- Lock-protected session storage

**Concurrency Pattern:**
```nim
# Each connection runs in its own task
proc handleWebSocket(ws: WebSocket) {.gcsafe.} =
  let session = createSession()

  while ws.connected:
    let data = ws.receive()
    handleProtocolMessage(session, data)
```

### 3. Protocol Handler (`src/network/protocol.nim`)

**Responsibilities:**
- Binary message encoding/decoding
- Command dispatch
- Validation and error handling

**Key Structures:**
```nim
type
  Request* = object
    command*: Command
    seq*: uint32
    key*: string
    value*: string

  Response* = object
    status*: ResponseStatus
    seq*: uint32
    value*: string
```

**Encoding/Decoding:**
- Big-endian byte order for all multi-byte values
- Size validation (max key: 64KB, max value: 32MB)
- CRC32 not used (rely on TCP/WebSocket integrity)

### 4. Session Manager (`src/network/session.nim`)

**Responsibilities:**
- Per-connection state management
- Current barrel tracking
- Barrel lifecycle management

**Data Structures:**
```nim
type
  Session* = object
    sessionId*: string
    currentBarrel*: string
    # Additional metadata...

  BarrelRegistry* = object
    barrels*: Table[string, Barrel]
    lock*: Lock
```

**Barrel Lifecycle:**
0. DISCOVERY: Barrels automatically detected on server startup, YAML configs created
1. CREATE_BARREL: Instantiate new Barrel object (for new barrels)
2. OPEN_BARREL: Explicitly load barrel from disk (optional for discovered barrels)
3. Lazy Loading: Discovered barrels opened automatically via `getBarrel()` on first access
4. USE_BARREL: Set as current for session
5. CLOSE_BARREL: Remove from session (can be reopened via lazy loading)
6. DROP_BARREL: Delete barrel and data files

**Note:** Discovered barrels don't require explicit OPEN_BARREL calls - they are lazy-loaded on first access through `getBarrel()`.

### 5. Barrel Registry

**Responsibilities:**
- Global barrel management
- Thread-safe barrel access
- Reference counting (future)

**Thread Safety:**
```nim
proc getBarrel*(registry: var BarrelRegistry,
                name: string): Barrel =
  withLock(registry.lock):
    result = registry.barrels.getOrDefault(name)
```

**Concurrent Access Pattern:**
- Lock-protected hash table
- Multiple readers, single writer
- No lock-free operations currently

### 6. Pub/Sub System (`src/pubsub/`)

**Responsibilities:**
- Real-time topic-based publish/subscribe messaging
- Pattern matching with Redis-style glob patterns (`*`)
- Presence tracking for topic subscribers
- Message history storage and replay
- Key-value change event integration
- WebSocket event delivery (command 0xFF)

**Key Components:**
- `PubSubManager` (`src/pubsub/manager.nim`): Core topic and subscription management
- `EventBroker` (`src/pubsub/eventbroker.nim`): Routes messages to WebSocket clients
- `PresenceManager` (`src/pubsub/presence.nim`): Tracks online users in topics
- `HistoryStore` (`src/pubsub/history.nim`): Stores message history for replay
- `Barrel hooks` (`src/pubsub/barrel_hooks.nim`): Integrates k/v operations with Pub/Sub

**Protocol Integration:**
- Commands 0x40-0x46: `SUBSCRIBE`, `UNSUBSCRIBE`, `PUBLISH`, `LIST_SUBSCRIBERS`, `HISTORY`, `LIST_TOPICS`, `PRESENCE`
- Event command 0xFF: Async server-to-client message delivery
- Message types: `mtData` (0), `mtPresence` (1), `mtKvChange` (2)

**Barrel Integration:**
- K/V operations (`set()`, `delete()`) automatically trigger Pub/Sub events
- Event topics: `kv:{barrelName}:{key}` (e.g., `kv:mybarrel:user:1000`)
- Hooks registered globally and triggered on barrel operations

**Pattern Matching:**
- Redis-style glob patterns: `user:*`, `chat:*:messages`, `sensor/*/temperature`
- Single `*` wildcard matches any characters within a topic segment
- Efficient pattern matching using prefix trees

**Thread Safety:**
- Lock-protected data structures for all shared state
- `{.acyclic.}` types and raw pointers to prevent ORC cycle detection crashes
- `{.gcsafe.}` blocks for thread-safe operations

## Threading Model

### Server Threading

```
Main Thread (MummyX):
  ├─ Accept connections
  ├─ Spawn task per connection
  └─ Manage worker pool

Worker Tasks (TaskPools):
  ├─ Handle WebSocket frames
  ├─ Process protocol messages
  ├─ Access shared barrel registry
  └─ Send responses

Background Thread (Compaction):
  └─ Perform data file compaction
```

### Client Threading

```
Client Thread:
  ├─ Manage single WebSocket connection
  ├─ Serialize requests
  ├─ Wait for responses
  └─ Handle timeouts

# No background threads in client
# All operations are synchronous
```

## Data Flow

### Request Processing Flow

```
1. Client sends WebSocket frame
   ↓
2. Server receives and unframes
   ↓
3. Protocol decode validates message
   ↓
4. Command dispatcher routes to handler
   ↓
5. Handler accesses storage engine
   ↓
6. Storage engine performs operation
   ↓
7. Response encoded and sent
   ↓
8. Client receives and correlates
```

### Example: GET Request

```
Client                              Server
  |                                   |
  |-- WebSocket Frame (binary) ----> |
  |    [GET][seq=5][key="user:1"]    |
  |                                   |
  |                                   |-- Decode protocol
  |                                   |-- Look up in KeyDir
  |                                   |-- Read from data file
  |                                   |-- Encode response
  |                                   |
  |<-- WebSocket Frame (binary) ----- |
  |    [OK][seq=5][value="Alice"]    |
  |                                   |
```

### Pub/Sub Event Flow

Pub/Sub events flow bidirectionally:
- **Client-to-server:** Pub/Sub commands (0x40-0x46) follow the standard request/response flow
- **Server-to-client:** Event messages (command 0xFF) are pushed asynchronously

**Subscription Flow:**
```
1. Client sends SUBSCRIBE command (0x40)
   ↓
2. Server adds subscription to PubSubManager
   ↓
3. Server sends subscription ID response
   ↓
4. Client tracks subscription locally
```

**Publish/Event Delivery Flow:**
```
1. Client A sends PUBLISH command (0x42) to topic
   ↓
2. Server routes message to PubSubManager
   ↓
3. PubSubManager matches topic against patterns
   ↓
4. For each matching subscription:
      a. EventBroker encodes event (command 0xFF)
      b. Event sent to subscribed client's WebSocket
   ↓
5. Client B receives event via onMessage callback
```

**Key-Value Change Event Flow:**
```
1. Client performs SET/DELETE operation on barrel
   ↓
2. Storage engine triggers barrel hooks
   ↓
3. Hook publishes k/v change event to Pub/Sub system
   ↓
4. Event routed to subscribers of `kv:{barrel}:{key}` topic
   ↓
5. Subscribed clients receive mtKvChange events
```

## Memory Management

### Client Memory
- Connection buffer: grows with largest message
- No internal caching (client-side)
- Strings passed by value (Nim's copy-on-write)

### Server Memory
- Session storage: ~100 bytes per connection
- Barrel registry: ~50 bytes per barrel entry
- KeyDir: ~40 bytes per key entry (24-byte struct + table overhead)
- No per-operation allocations in hot path

## Performance Considerations

### Client Performance
- **Connection reuse:** Single connection for multiple operations
- **Request pipelining:** Not implemented (synchronous only)
- **Buffer reuse:** Single buffer per client reused
- **No GC pressure:** Minimal allocations

### Server Performance
- **Lock contention:** Lock-protected barrel registry
- **Connection scaling:** Each connection uses ~10KB memory
- **Task scheduling:** MummyX event loop with TaskPools
- **I/O model:** Blocking I/O per connection

### Pub/Sub Performance

**Event Throughput:**
- **Publish operations:** ~30,000 messages/sec (local, single topic)
- **Event delivery:** ~20,000 events/sec per connection (depends on subscribers)
- **Pattern matching:** O(k) where k = topic length (efficient prefix trees)

**Memory Usage:**
- **Per subscription:** ~64 bytes (topic pattern + client reference)
- **Per topic:** ~128 bytes (metadata + subscriber list)
- **Message history:** Configurable retention (default: 100 messages/topic)

**Scalability Considerations:**
- **Fan-out:** Single publish to N subscribers = N event deliveries
- **Pattern complexity:** Complex patterns (`a/*/b/*/c`) require more matching time
- **History storage:** Older messages automatically purged based on configuration

**Optimizations:**
- **Batch event encoding:** Multiple events encoded together when possible
- **Lazy pattern evaluation:** Patterns evaluated only when topics change
- **Connection affinity:** Subscribers on same connection share event encoding

**Measured Performance:**
- Single connection: ~50,000 ops/sec (local)
- Multiple connections: Linear scaling with cores
- Connection overhead: ~10ms establishment time
- Memory per connection: ~10KB baseline

## Security Architecture

### Authentication & Authorization

BitBarrel supports JWT-based authentication with role-based access control (RBAC).

**JWT Authentication (Built-in):**
- Algorithm: HS256 (HMAC SHA-256)
- Token format: `Authorization: Bearer <base64-jwt>`
- Token claims: `sub` (username), `roles` (array), `iat` (issued), `exp` (expiry)
- Three RBAC roles: `admin`, `readwrite`, `readonly`

**Authorization Model:**

| Operation | admin | readwrite | readonly |
|-----------|-------|-----------|----------|
| Barrel management: CREATE, OPEN, DROP | YES | NO | NO |
| Write operations: SET, DELETE | YES | YES | NO |
| Pub/Sub subscribe operations: SUBSCRIBE, UNSUBSCRIBE, LIST_SUBSCRIBERS, HISTORY, LIST_TOPICS, PRESENCE | YES | YES | YES |
| Pub/Sub publish operations: PUBLISH | YES | YES | NO |
| Read operations: GET, EXISTS, COUNT, RANGE, PREFIX | YES | YES | YES |

### Current State
- **No encryption:** Plain TCP/WebSocket; use TLS/WSS in production
- **Authentication:** JWT tokens with RBAC (optional, disabled by default)
- **Input validation:** Size limits and format validation
- **Pub/Sub authorization:** Not yet integrated with RBAC (planned)
- **Rate limiting:** Not implemented; use reverse proxy for production

### Recommended Deployment

**Option 1: Built-in JWT (Simple)**
```
Client --TLS--> BitBarrel Server
                      ↓
                JWT Token verification
                RBAC authorization checks
```

**Option 2: External Proxy (Complex):**
```
Client <--TLS--> Proxy (nginx/HAProxy) <--TLS--> BitBarrel Server
                      ↓
                TLS Client Cert or OIDC token
                Proxy ACL rules
                Rate limiting
                Connection pooling
```

### JWT Configuration

**YAML:**
```yaml
auth:
  enabled: true
  secret: "production-secret-key-32-chars-minimum"
  default_token_expiry_hours: 24

users:
  - username: "admin"
    roles: ["admin"]
  - username: "readwrite"
    roles: ["readwrite"]
  - username: "readonly"
    roles: ["readonly"]
```

**Environment:**
```bash
BITBARREL_AUTH_ENABLED=true
BITBARREL_AUTH_SECRET="production-secret-key"
```

## Scalability

### Horizontal Scaling
- Server: Single instance (no clustering)
- Scaling: Run multiple instances, shard by barrel
- Load balancing: Use consistent hashing on barrel name

### Vertical Scaling
- CPU: More cores = more concurrent connections
- Memory: More RAM = larger KeyDir
- Disk: SSD recommended for data files

### Limits
- Max connections: ~10,000 (OS file descriptor limit)
- Max barrels: Limited by memory (registry size)
- Max keys per barrel: Limited by KeyDir memory

## REST API Architecture

### Design Principles
- Simple HTTP endpoints for basic operations
- No authentication (delegate to reverse proxy)
- JSON responses for easy integration
- RESTful resource naming

### Endpoint Structure
```
GET    /barrels/{name}/kv/{key}    # RESTful resource path
PUT    /barrels/{name}/kv/{key}    # Idempotent operations
DELETE /barrels/{name}/kv/{key}    # Explicit deletion
HEAD   /barrels/{name}/kv/{key}    # Metadata only
```

### Implementation
```nim
# HTTP handlers delegate to protocol handlers
proc handleGetKV(req: Request, res: Response) =
  let barrel = req.pathParams["name"]
  let key = req.pathParams["key"]

  session.useBarrel(barrel)
  let value = session.get(key)

  res.status = Http200
  res.body = value
```

## Future Architecture Directions

### 1. Async Client
```nim
# Proposed async API
proc asyncSet(client: BitBarrelClient,
              key, value: string,
              callback: proc(status: ResponseStatus))
```

### 2. Connection Pooling
```nim
type ConnectionPool* = object
  clients*: seq[BitBarrelClient]
  currentIndex*: int
  lock*: Lock

proc getClient*(pool: var ConnectionPool): BitBarrelClient
```

### 3. Native Clustering
```nim
# Multi-node awareness
type Cluster* = object
  nodes*: seq[Node]
  partitioner*: PartitionFunction

proc getNode*(cluster: Cluster, key: string): Node
```

### 4. Pub/Sub (Now Implemented)

Pub/Sub messaging is now fully implemented as part of BitBarrel's real-time capabilities. See the [Pub/Sub System](#6-pubsub-system-srcpubsub) section for architecture details and the [Pub/Sub User Guide](../USER_GUIDE/pubsub.md) for usage examples.

**Key Features:**
- Topic-based publish/subscribe with Redis-style pattern matching (`*`)
- Three message types: data, presence notifications, and key-value change events
- Presence tracking for topic subscribers
- Message history storage and replay
- Automatic k/v change event integration

**Status:** ✅ Complete (server and client libraries)

## Deployment Patterns

### Single Instance
```
┌─────────────────────────┐
│    BitBarrel Server     │
│   (Embedded + Network)  │
└──────────┬──────────────┘
           │
     ┌─────┴──────┐
     ↓            ↓
[Clients]    [Local API]
```

### With Reverse Proxy
```
┌──────────┐    ┌──────────────┐    ┌────────────────┐
│ [Client] │───→│ nginx/HAProxy│───→│ BitBarrel      │
└──────────┘    │ - SSL        │    │ - Port 9876    │
   ...         │ - Auth       │    └────────────────┘
┌──────────┐    │ - Rate limit │
│ [Client] │───→└──────────────┘
└──────────┘
```

### Multi-Instance with Sharding
```
┌──────────┐         ┌─────────────────┐
│ [Client] │────────→│ Router/Load Bal │
└──────────┘         └────────┬────────┘
        ┌─────────────────────┼─────────────────────┐
        ↓                     ↓                     ↓
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ BitBarrel A  │    │ BitBarrel B  │    │ BitBarrel C  │
│ - Barrels 0…2│    │ - Barrels 3…5│    │ - Barrels 6…8│
└──────────────┘    └──────────────┘    └──────────────┘
```

## Monitoring and Observability

### Current Metrics
- Server: connection count, requests/sec, error rates
- Client: operation latency, error count, retry attempts
- Storage: key count, data size, compaction stats

### Future Monitoring
```nim
type Metrics* = object
  requestsTotal*: Counter
  requestsLatency*: Histogram
  errorsTotal*: Counter
  activeConnections*: Gauge
```

## Conclusion

BitBarrel's network architecture prioritizes:
- **Simplicity:** Easy to understand and maintain
- **Performance:** Minimal overhead protocol
- **Reliability:** TCP/WebSocket reliability guarantees
- **Scalability:** Single-instance vertical scaling
- **Real-time messaging:** Pub/Sub with pattern matching and presence tracking

The architecture serves the primary use case of providing remote access to BitBarrel's high-performance embedded storage while maintaining the simplicity and reliability of the core design. The addition of Pub/Sub messaging extends BitBarrel's capabilities to real-time event-driven applications.

For questions or contributions, see the main documentation or GitHub repository.
