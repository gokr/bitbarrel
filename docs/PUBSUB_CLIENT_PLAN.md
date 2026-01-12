# PubSub Client Implementation Plan

This document outlines the plan for implementing PubSub functionality across all BitBarrel client libraries, mirroring the reference implementation in the Nim client.

## Current Status

- **Nim client**: ✅ Full PubSub implementation with tests
- **Go client**: ❌ No PubSub support
- **Python client**: ❌ No PubSub support
- **Dart/Flutter client**: ❌ No PubSub support
- **TypeScript client**: ❌ No PubSub support

## Reference Implementation: Nim Client

The Nim client provides the reference implementation located at `clients/nim/`:

### Core Protocol Functions (`protocol.nim`)

#### Commands Added (0x40-0x46)
| Command | Value | Description |
|---------|-------|-------------|
| `cmdSubscribe` | 0x40 | Subscribe to a topic |
| `cmdUnsubscribe` | 0x41 | Unsubscribe from a topic |
| `cmdPublish` | 0x42 | Publish a message to a topic |
| `cmdListSubscribers` | 0x43 | List topic subscribers |
| `cmdHistory` | 0x44 | Get message history |
| `cmdListTopics` | 0x45 | List all topics |
| `cmdPresence` | 0x46 | Get presence information |

#### Protocol Formats

**Subscribe Request:** `[options:1][topicLen:2][topic:N][patternLen:2][pattern:M]`

**Options Byte:**
- Bit 0 (0x01): `enableKvEvents` - Subscribe to key-value change events
- Bit 1 (0x02): `enablePresence` - Join presence tracking
- Bit 2 (0x04): `replayHistory` - Send recent messages on subscribe

**Publish Request:** `[topicLen:2][topic:N][msgType:1][headersLen:4][headers:M][payloadLen:4][payload:P]`

**PubSub Event (0xFF push):** `[cmd:1][seq:4][topicLen:2][topic][msgType:1][seq:8][ts:8][headersLen:4][headers][payloadLen:4][payload]`

#### Types Defined

```nim
PubSubMessageType = enum
  mtData = 0      # Normal data message
  mtPresence = 1  # Presence notification

PubSubEvent = object
  topic*: string
  messageType*: PubSubMessageType
  sequence*: uint64
  timestamp*: int64
  headers*: string
  payload*: string

SubscriptionOptions = object
  enableKvEvents*: bool
  enablePresence*: bool
  replayHistory*: bool

PresenceMember = object
  clientId*: uint64
  joinedAt*: int64
  lastPing*: int64

PresenceInfo = object
  topic*: string
  members*: seq[PresenceMember]
  lastUpdate*: int64

SubscriptionInfo = object
  id*: string
  topic*: string
  pattern*: string
```

### Client API (`client.nim`)

#### Methods to Implement

1. **`subscribe(topic, pattern, options) -> string`**
   - Returns subscription ID
   - Supports pattern matching with wildcards (`*`)
   - Options for KV events, presence, history replay

2. **`subscribe(topic) -> string`** (convenience)
   - Subscribes to exact topic with default options

3. **`isSubscribed(subId) -> bool`**
   - Check if subscription is active

4. **`unsubscribe(subId) -> bool`**
   - Remove specific subscription

5. **`unsubscribeAll() -> int`**
   - Remove all subscriptions, returns count

6. **`publish(topic, messageType, payload, headers) -> uint64`**
   - Publish message, returns sequence number

7. **`publish(topic, messageType, payload) -> uint64`** (convenience)
8. **`publish(topic, payload) -> uint64`** (convenience)

9. **`listSubscribers(topic) -> seq[SubscriptionInfo]`**
   - Get list of topic subscribers

10. **`history(topic, limit, sinceSeq) -> seq[PubSubEvent]`**
    - Get message history

11. **`presence(topic) -> PresenceInfo`**
    - Get presence information

12. **`listTopics() -> seq[string]`**
    - List all available topics

#### Message Handling

Push events are detected via `isPubSubEvent(data)` which checks for command 0xFF. Events are decoded and delivered to the `onMessage` callback:

```nim
client.onMessage = proc(event: PubSubEvent) {.closure, gcsafe.} =
  {.gcsafe.}:
    # Handle event
```

### Test Coverage (`tests/test_pubsub.nim`)

#### Test Suite
1. **subscribe to topic** - Basic subscription
2. **publish message** - Basic publish
3. **subscribe and receive message** - Receive push events
4. **pattern subscription** - Wildcard matching
5. **unsubscribe all** - Bulk unsubscribe

#### Test Utilities
- `uniqueTopicName(prefix)` - Generate unique topic names
- Event collection via callback
- Async message waiting with timeout

---

## Implementation Plan by Client

### 1. Go Client (`clients/go/`)

#### Files to Modify/Add

**New Files:**
- `pubsub.go` - PubSub types and client methods
- `pubsub_test.go` - Test suite

**Modified Files:**
- `types.go` - Add PubSub types
- `protocol.go` - Add encoding/decoding functions

#### Implementation Tasks

1. **Protocol Layer (`protocol.go`)**
   - [ ] Add `CmdSubscribe`, `CmdUnsubscribe`, `CmdPublish`, etc. constants
   - [ ] Add `PubSubMessageType` enum
   - [ ] Implement `EncodeSubscribeRequest(topic, pattern, opts)`
   - [ ] Implement `DecodeSubscribeResponse(data) -> string`
   - [ ] Implement `EncodePublishRequest(topic, msgType, payload, headers)`
   - [ ] Implement `DecodePublishResponse(data) -> uint64`
   - [ ] Implement `DecodePubSubEvent(data) -> PubSubEvent`
   - [ ] Implement `IsPubSubEvent(data) -> bool`

2. **Types (`types.go`)**
   - [ ] Add `PubSubMessageType` enum (Data, Presence)
   - [ ] Add `PubSubEvent` struct
   - [ ] Add `SubscriptionOptions` struct
   - [ ] Add `PresenceMember` struct
   - [ ] Add `PresenceInfo` struct
   - [ ] Add `SubscriptionInfo` struct

3. **Client API (`pubsub.go`)**
   - [ ] `Subscribe(topic string) (string, error)`
   - [ ] `SubscribeWithOptions(topic string, pattern string, opts SubscriptionOptions) (string, error)`
   - [ ] `IsSubscribed(subId string) bool`
   - [ ] `Unsubscribe(subId string) bool`
   - [ ] `UnsubscribeAll() int`
   - [ ] `Publish(topic string, payload string) (uint64, error)`
   - [ ] `PublishWithType(topic string, msgType PubSubMessageType, payload string, headers string) (uint64, error)`
   - [ ] `ListSubscribers(topic string) ([]SubscriptionInfo, error)`
   - [ ] `History(topic string, limit int, sinceSeq uint64) ([]PubSubEvent, error)`
   - [ ] `Presence(topic string) (PresenceInfo, error)`
   - [ ] `ListTopics() ([]string, error)`

4. **Message Handling**
   - [ ] Add `OnMessage callback func(event PubSubEvent)` to Client struct
   - [ ] Modify `receiveMessages()` to call `IsPubSubEvent()` and handle push events
   - [ ] Manage subscriptions map in Client struct

5. **Tests (`pubsub_test.go`)**
   - [ ] `TestSubscribeToTopic`
   - [ ] `TestPublishMessage`
   - [ ] `TestSubscribeAndReceiveMessage`
   - [ ] `TestPatternSubscription`
   - [ ] `TestUnsubscribeAll`

#### Go-Specific Considerations
- Use `sync.Map` for subscriptions (thread-safe without explicit locks)
- Goroutine-based message loop for push event handling
- Context-based timeout for async operations

---

### 2. Python Client (`clients/python/`)

#### Files to Modify/Add

**New Files:**
- `pubsub.py` - PubSub functionality
- `tests/test_pubsub.py` - Test suite

**Modified Files:**
- `protocol.py` - Add encoding/decoding functions
- `client.py` - Add PubSub methods

#### Implementation Tasks

1. **Protocol Layer (`protocol.py`)**
   - [ ] Add Command enum values (SUBSCRIBE=0x40, etc.)
   - [ ] Add PubSubMessageType enum
   - [ ] Implement `encode_subscribe_request(topic, pattern, opts)`
   - [ ] Implement `decode_subscribe_response(data) -> str`
   - [ ] Implement `encode_publish_request(topic, msg_type, payload, headers)`
   - [ ] Implement `decode_publish_response(data) -> int`
   - [ ] Implement `decode_pubsub_event(data) -> PubSubEvent`
   - [ ] Implement `is_pubsub_event(data) -> bool`

2. **Types (`client.py` or new `types.py`)**
   - [ ] Add PubSubMessageType enum
   - [ ] Add PubSubEvent dataclass
   - [ ] Add SubscriptionOptions dataclass
   - [ ] Add PresenceMember dataclass
   - [ ] Add PresenceInfo dataclass
   - [ ] Add SubscriptionInfo dataclass

3. **Client API (`client.py` or `pubsub.py`)**
   - [ ] `subscribe(topic, pattern=None, options=None) -> str`
   - [ ] `is_subscribed(sub_id) -> bool`
   - [ ] `unsubscribe(sub_id) -> bool`
   - [ ] `unsubscribe_all() -> int`
   - [ ] `publish(topic, payload, msg_type=None, headers=None) -> int`
   - [ ] `list_subscribers(topic) -> List[SubscriptionInfo]`
   - [ ] `history(topic, limit=100, since_seq=0) -> List[PubSubEvent]`
   - [ ] `presence(topic) -> PresenceInfo`
   - [ ] `list_topics() -> List[str]`

4. **Message Handling**
   - [ ] Add `on_message: Callable[[PubSubEvent], None]` to Client
   - [ ] Modify message receive loop to handle 0xFF command events
   - [ ] Manage subscriptions dictionary with thread-safety

5. **Tests (`tests/test_pubsub.py`)**
   - [ ] `test_subscribe_to_topic`
   - [ ] `test_publish_message`
   - [ ] `test_subscribe_and_receive_message`
   - [ ] `test_pattern_subscription`
   - [ ] `test_unsubscribe_all`

#### Python-Specific Considerations
- Use `threading.Lock` for thread-safety
- Use `Callable` type hints for callbacks
- Support `asyncio` as optional alternative

---

### 3. Dart/Flutter Client (`clients/dart/`)

#### Files to Modify/Add

**New Files:**
- `lib/src/pubsub.dart` - PubSub functionality
- `test/pubsub_test.dart` - Test suite

**Modified Files:**
- `lib/src/protocol/commands.dart` - Add command enums
- `lib/src/protocol/decoder.dart` - Add decode functions
- `lib/src/protocol/encoder.dart` - Add encode functions
- `lib/src/client.dart` - Add PubSub methods
- `lib/src/types.dart` - Add PubSub types

#### Implementation Tasks

1. **Protocol Layer**
   - [ ] Add Command enum values
   - [ ] Add PubSubMessageType enum
   - [ ] Implement subscription/publish encoding/decoding
   - [ ] Implement event decoding

2. **Types**
   - [ ] Add all PubSub types with proper Dart typing

3. **Client API**
   - [ ] All subscribe methods (sync and async where appropriate)
   - [ ] All unsubscribe methods
   - [ ] `publish()` methods
   - [ ] Query methods (listSubscribers, history, presence, listTopics)

4. **Message Handling**
   - [ ] Add `onMessage` Stream<PubSubEvent>
   - [ ] Handle push events in WebSocket message handler
   - [ ] Stream-based API for reactive programming

5. **Tests**
   - [ ] Full test suite mirroring Nim client

#### Dart/Flutter-Specific Considerations
- Use Streams for event delivery (idiomatic Dart)
- Support platform-specific WebSocket libraries
- Keep API compatible with Flutter's async/await
- Consider isolate usage for heavy event processing

---

### 4. TypeScript Client (`clients/typescript/`)

#### Files to Modify/Add

**New Files:**
- `src/pubsub.ts` - PubSub functionality
- `tests/pubsub.test.ts` - Test suite

**Modified Files:**
- `src/protocol.ts` - Add encoding/decoding
- `src/types.ts` - Add PubSub types
- `src/client.ts` - Add PubSub methods

#### Implementation Tasks

1. **Protocol Layer**
   - [ ] Add Command enum values
   - [ ] Add PubSubMessageType enum
   - [ ] Implement all encode/decode functions
   - [ ] Export types for external use

2. **Types**
   - [ ] TypeScript interfaces for all PubSub types
   - [ ] Type-safe enums

3. **Client API**
   - [ ] Type-safe subscribe methods
   - [ ] Unsubscribe methods
   - [ ] Publish methods
   - [ ] Query methods

4. **Message Handling**
   - [ ] Extend EventEmitter with PubSub events
   - [ ] `on('message', handler: PubSubEventHandler)`
   - [ ] `on('presence', handler: PresenceEventHandler)`

5. **Tests**
   - [ ] Complete test suite
   - [ ] Mock WebSocket for unit tests
   - [ ] Integration tests with real server

#### TypeScript-Specific Considerations
- Extend EventEmitter class
- Use strong typing throughout
- Support both CommonJS and ESM exports
- Consider `rxjs` Observables as optional extension

---

## Testing Strategy

### Common Test Requirements

All clients should implement tests that match the Nim client's test suite:

1. **Server Setup**
   - Tests require running BitBarrel server on localhost:9876
   - Skip tests gracefully if server not available
   - Use unique topic names to avoid conflicts

2. **Helper Functions**
   - `uniqueTopicName(prefix)` - Generate unique topics
   - Event collection mechanisms
   - Async wait helpers with timeout

3. **Test Categories**

| Test | Description |
|------|-------------|
| Subscribe to topic | Basic subscription, verify subId |
| Publish message | Publish, verify sequence number |
| Subscribe and receive | Subscribe, publish, receive push event |
| Pattern subscription | Wildcard matching with `*` |
| Unsubscribe all | Multiple subs, clear all |

### Test Execution

Add to existing `testClients` nimble task:
- Run PubSub tests for each client
- Report failures clearly
- Mark PubSub as feature-complete when all pass

---

## Protocol Format Summary

### Subscribe Request (0x40)
```
[options:1][topicLen:2][topic:N][patternLen:2][pattern:M]
```
- options byte: bit0=KV events, bit1=Presence, bit2=Replay history
- topic: exact topic name or empty for pattern-only
- pattern: wildcard pattern (e.g., "user/*")

### Publish Request (0x42)
```
[topicLen:2][topic:N][msgType:1][headersLen:4][headers:M][payloadLen:4][payload:P]
```
- msgType: 0=Data, 1=Presence
- headers: JSON string (optional)
- payload: message content

### PubSub Event (0xFF - Push)
```
[cmd:1][seq:4][topicLen:2][topic][msgType:1][seq:8][ts:8][headersLen:4][headers][payloadLen:4][payload]
```
- Sent to subscribed clients when messages published
- Must be detected and decoded separately from responses

---

## Sequence Diagram

```
Client                          Server
  |                               |
  |--- SUBSCRIBE topic=* ---------->|
  |<-- OK (subId: "uuid1") ---------|
  |                               |
  |                               |
  |--- PUBLISH "user/login" ------>|
  |<-- OK (seq: 123) --------------|
  |                               |
  |--- PUSH EVENT (0xFF) ---------| (to all subscribers of "user/*")
  |<-- event for topic="user/login"|
  |                               |
```

---

## Dependencies

| Client | New Dependencies |
|--------|-----------------|
| Go | None (stdlib sufficient) |
| Python | None (stdlib sufficient) |
| Dart | None (stdlib sufficient) |
| TypeScript | None (already uses EventEmitter) |

---

## Timeline Estimate

| Client | Estimated Lines | Implementation Time | Testing Time |
|--------|----------------|---------------------|--------------|
| Go | ~400 loC | 4-6 hours | 2-3 hours |
| Python | ~350 loC | 3-5 hours | 2-3 hours |
| Dart | ~450 loC | 4-6 hours | 2-3 hours |
| TypeScript | ~400 loC | 3-5 hours | 2-3 hours |

**Total**: ~1600 lines of code, 14-22 hours implementation, 8-12 hours testing

---

## Success Criteria

- [ ] All clients implemented PubSub with matching API
- [ ] All clients have full test coverage mirroring Nim client
- [ ] `nimble testClients` includes PubSub tests for all clients
- [ ] Documentation updated for each client's PubSub API
- [ ] Examples added for each client

---

## References

- Nim Client Reference: `clients/nim/src/bitbarrel_client/protocol.nim` (lines 607-700+)
- Nim Client API: `clients/nim/src/bitbarrel_client/client.nim` (lines 872-1000+)
- Nim Tests: `clients/nim/tests/test_pubsub.nim`
- Protocol Spec: `docs/PROTOCOL.md` (PubSub section)
