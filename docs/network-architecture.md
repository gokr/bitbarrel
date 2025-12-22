# BitBarrel Network Architecture

This document describes the architecture of BitBarrel's network protocol implementation, including the client-server model, session management, and threading model.

## Overview

BitBarrel's network layer provides remote access to the embedded key-value store through:
- **Binary Protocol:** Efficient WebSocket-based protocol for key-value operations
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
├──────────────┬──────────────┬───────────────────────────────┤
│   Protocol   │   Session    │          REST API             │
│   Handler    │  Manager     │         Endpoints             │
├──────────────┴──────────────┴───────────────────────────────┤
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
- Size validation (max key: 64KB, max value: 1MB)
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
1. CREATE_BARREL: Instantiate new Barrel object
2. OPEN_BARREL: Load existing barrel from disk
3. USE_BARREL: Set as current for session
4. CLOSE_BARREL: Remove from session
5. DROP_BARREL: Delete barrel and data files

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

## Memory Management

### Client Memory
- Connection buffer: grows with largest message
- No internal caching (client-side)
- Strings passed by value (Nim's copy-on-write)

### Server Memory
- Session storage: ~100 bytes per connection
- Barrel registry: ~50 bytes per barrel entry
- KeyDir: 8 bytes per key entry (pointer + size)
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

**Measured Performance:**
- Single connection: ~50,000 ops/sec (local)
- Multiple connections: Linear scaling with cores
- Connection overhead: ~10ms establishment time
- Memory per connection: ~10KB baseline

## Security Architecture

### Current State
- **No encryption:** Plain TCP/WebSocket
- **No authentication:** Accepts all connections
- **No authorization:** Full access to all barrels
- **Input validation:** Size limits and format validation

### Recommended Deployment
```
Client <--TLS--> Proxy (nginx/HAProxy) <--TCP--> BitBarrel Server
                      ↓
                Authentication/Authorization
                Rate Limiting
                Connection Pooling
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

### 4. Pub/Sub
```nim
# Event notifications
proc subscribe*(client: BitBarrelClient,
                pattern: string,
                callback: proc(event: Event))
```

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

The architecture serves the primary use case of providing remote access to BitBarrel's high-performance embedded storage while maintaining the simplicity and reliability of the core design.

For questions or contributions, see the main documentation or GitHub repository.
