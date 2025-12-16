# BitBarrel Pub/Sub Messaging System Implementation Plan

## Introduction
This plan outlines a generic pub/sub messaging system (like NATS/MQTT) built on top of BitBarrel, targeting medium scale (10K topics, 10K msgs/sec) with hybrid storage for chat room and similar use cases.

## Design Overview

### 1. Pub/Sub Architecture
```
┌─────────────────────────────────────────────┐
│  WebSocket/HTTP API                         │  Client connections
├─────────────────────────────────────────────┤
│  PubSubBroker (topics, subscriptions)      │  Message routing
├─────────────────────────────────────────────┤
│  Message Store (BitBarrel integration)      │  Persistence layer
│  • In-memory ring buffer (recent messages) │  Fast access
│  • BitBarrel storage (persistent)          │  Long-term storage
└─────────────────────────────────────────────┘
```

### 2. Core Components
- **PubSubBroker**: Central message router managing topics and subscriptions
- **Message**: Immutable message structure with metadata
- **Subscription**: Tracks topic subscribers with delivery state
- **MessageStore**: Hybrid storage combining memory and BitBarrel

### 3. Data Model
```nim
Message* = object
  id*: string               # UUID
  topic*: string            # Topic/channel name
  payload*: string          # Message content
  timestamp*: int64         # Unix timestamp
  sequence*: uint64         # Topic-specific sequence number
  headers*: Table[string, string]  # Optional metadata

Subscription* = object
  id*: string               # Subscription ID
  topic*: string            # Subscribed topic
  clientId*: string         # Client identifier
  lastDelivered*: uint64    # Last sequence number delivered
  created*: int64
```

## Implementation Strategy

### Phase 1: Pub/Sub Broker Core
1. Create `src/pubsub/broker.nim`:
   - Topic management with hash table lookup
   - In-memory subscriber tracking
   - Message routing with sequence numbers
   - Connection management

2. Create `src/pubsub/types.nim`:
   - Message and subscription types
   - Broker configuration
   - Client statistics

### Phase 2: Hybrid Message Storage
1. Create `src/pubsub/messagestore.nim`:
   - In-memory ring buffer per topic (configurable size)
   - BitBarrel backend for persistence
   - Message expiration and cleanup

2. Storage strategy:
   - Key format: `"msg:{topic}:{sequence}"` → message data
   - Topic metadata: `"meta:{topic}"` → topic stats
   - Client state: `"client:{clientId}:{topic}"` → last delivered

### Phase 3: Protocol Handlers
1. Create `src/pubsub/protocol.nim`:
   - Message serialization (JSON/MsgPack)
   - Command handling (SUB, UNSUB, PUB, ACK)
   - Error responses

2. Create `src/pubsub/websocket_handler.nim`:
   - WebSocket upgrade handling
   - Bidirectional message flow
   - Ping/pong for connection health

### Phase 4: BitBarrel Integration
1. Message persistence pattern:
   ```nim
   # Store message with composite key
   let key = "msg:" & topic & ":" & $sequence
   barrel.set(key, message.toJson())

   # Update topic metadata
   let metaKey = "meta:" & topic
   barrel.set(metaKey, %{"lastSeq": sequence, "lastTs": timestamp})
   ```

2. Recovery process:
   - Load topic metadata on startup
   - Rebuild in-memory indexes from persistent state
   - Handle message gaps during recovery

### Phase 5: WebSocket Server
1. Create `src/websocket/pubsub_server.nim`:
   - Multi-client connection management
   - Authentication (optional)
   - Rate limiting and backpressure

2. Message flow:
   - PUB command → validate → store → broadcast to subscribers
   - SUB command → register → catch-up delivery → real-time delivery

## Performance Optimizations

1. **In-memory Ring Buffers**: Recent messages (configurable, e.g., last 1000) kept in memory per topic
2. **Batch Persistence**: Messages written to BitBarrel in batches to reduce disk I/O
3. **Sequence Number Gaps**: Use uint64 sequence numbers for O(1) ordering and gap detection
4. **Connection Pooling**: Reuse WebSocket connections for multiple subscriptions
5. **Lazy Loading**: Load topic history only when subscribers request catch-up

## Threading Model

Following BitBarrel's proven patterns:
- **Broker Thread**: Main message routing and client management
- **Persistence Thread**: Batch writing to BitBarrel (like write buffer)
- **Per-client Read Threads**: WebSocket message delivery
- All threads use `{.gcsafe.}` blocks and lock-protected shared state

## Scale Considerations (10K topics, 10K msgs/sec)

1. **Topic Sharding**: For large topic counts, use range-based sharding
2. **Memory Management**: Configurable ring buffer sizes per topic
3. **Backpressure**: Slow subscriber detection and optional disconnection
4. **Message Retention**: Time-based size limits for topic history

## Protocol Specification

### WebSocket Commands
```json
// Subscribe to topic
{"op": "sub", "topic": "chat.room1", "seq": 0}

// Publish message
{"op": "pub", "topic": "chat.room1", "payload": "Hello!"}

// Message delivery
{"op": "msg", "topic": "chat.room1", "seq": 123, "payload": "Hello!", "ts": 1704067200}

// Acknowledge delivery
{"op": "ack", "topic": "chat.room1", "seq": 123}
```

## Critical Files to Create

1. `/home/gokr/tankfeud/kvs/src/pubsub/broker.nim` - Core message broker
2. `/home/gokr/tankfeud/kvs/src/pubsub/types.nim` - PubSub data structures
3. `/home/gokr/tankfeud/kvs/src/pubsub/messagestore.nim` - Hybrid storage layer
4. `/home/gokr/tankfeud/kvs/src/pubsub/protocol.nim` - Protocol handling
5. `/home/gokr/tankfeud/kvs/src/pubsub/websocket_handler.nim` - WebSocket logic
6. `/home/gokr/tankfeud/kvs/src/websocket/pubsub_server.nim` - WebSocket server
7. `/home/gokr/tankfeud/kvs/examples/pubsub_chat.nim` - Chat room demo

## Testing Strategy

1. Unit tests for broker logic and message routing
2. Storage layer tests (BitBarrel integration)
3. WebSocket protocol compliance tests
4. Performance benchmarks (10K concurrent clients)
5. Failure simulation (client disconnect, recovery)

## Configuration Example

```nim
# PubSub broker configuration
let config = PubSubConfig(
  maxTopics: 10000,
  messagesInMemory: 1000,  # Per topic
  persistenceBatch: 100,   # Batch size for BitBarrel
  maxMessageSize: 64 * 1024,  # 64KB
  retentionHours: 24 * 7,  # 1 week
  slowSubscriberThreshold: 5000  # milliseconds
)

# Initialize with BitBarrel
let barrel = openBarrel("./pubsub_data")
let broker = newPubSubBroker(barrel, config)
```

## Integration with BitBarrel

The pub/sub system uses BitBarrel as a persistence layer but doesn't modify BitBarrel's core. It treats BitBarrel as a durable key-value store:
- Messages are stored with composite keys
- Topic metadata tracks sequence numbers
- Client state is persisted for recovery scenarios
- Leverages BitBarrel's crash recovery for message durability

This design provides a clean separation: BitBarrel handles storage, while the pub/sub layer handles messaging semantics, scaling to medium workloads while maintaining simplicity.