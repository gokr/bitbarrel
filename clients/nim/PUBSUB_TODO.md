# Pub/Sub Implementation TODO

This document tracks what needs to be implemented to make the pub/sub tests pass.

## Protocol Types (protocol.nim)

### Commands
- [x] `cmdSubscribe = 0x40` - Subscribe to topic/pattern
- [x] `cmdUnsubscribe = 0x41` - Unsubscribe from subscription
- [x] `cmdPublish = 0x42` - Publish message to topic
- [ ] `cmdListSubscribers = 0x43` - List subscribers for topic
- [ ] `cmdHistory = 0x44` - Get message history
- [ ] `cmdListTopics = 0x45` - List all topics
- [ ] `cmdPresence = 0x46` - Get presence info for topic

### Types
- [x] `PubSubMessageType` enum (mtData, mtPresence, mtKvChange)
- [x] `PubSubEvent` object (topic, messageType, sequence, timestamp, headers, payload)
- [x] `SubscriptionOptions` object (enableKvEvents, enablePresence, replayHistory)
- [x] `PresenceInfo` object (topic, members, lastUpdate)
- [x] `PresenceMember` object (clientId, username, joinedAt, lastPing, metadata)

### Encoding/Decoding Functions
- [x] `encodeSubscribeRequest(topic, pattern, options)` -> string
- [x] `decodeSubscribeResponse(data)` -> subscriptionId
- [ ] `encodeUnsubscribeRequest(subId)` -> string
- [x] `encodePublishRequest(topic, msgType, payload, headers)` -> string
- [x] `decodePublishResponse(data)` -> sequence number
- [x] `decodePubSubEvent(data)` -> PubSubEvent
- [ ] `encodeListSubscribersRequest(topic)` -> string
- [ ] `decodeListSubscribersResponse(data)` -> seq[Subscription]
- [ ] `encodeHistoryRequest(topic, limit, sinceSeq)` -> string
- [ ] `decodeHistoryResponse(data)` -> seq[PubSubEvent]
- [ ] `encodeListTopicsRequest()` -> string
- [ ] `decodeListTopicsResponse(data)` -> seq[string]
- [ ] `encodePresenceRequest(topic)` -> string
- [ ] `decodePresenceResponse(data)` -> PresenceInfo

## Client Methods (client.nim)

### Properties
- [x] `onMessage: proc(event: PubSubEvent)` - Message handler callback

### Subscription Methods
- [x] `subscribe(topic: string): string` - Subscribe to exact topic
- [x] `subscribe(topic: string, options: SubscriptionOptions): string` - Subscribe with options
- [x] `isSubscribed(subId: string): bool` - Check if subscription is active
- [x] `unsubscribe(subId: string): bool` - Unsubscribe by ID
- [x] `unsubscribeAll(): int` - Unsubscribe from all, return count

### Publishing Methods
- [x] `publish(topic: string, payload: string): uint64` - Publish data message
- [x] `publish(topic: string, msgType: PubSubMessageType, payload: string): uint64`
- [x] `publish(topic: string, msgType: PubSubMessageType, payload: string, headers: string): uint64`

### Query Methods
- [ ] `listSubscribers(topic: string): seq[Subscription]` - Get subscribers for topic
- [ ] `listTopics(): seq[string]` - Get all topics
- [ ] `getHistory(topic: string, limit: int = 100, sinceSeq: uint64 = 0): seq[PubSubEvent]`
- [ ] `getPresence(topic: string): PresenceInfo` - Get presence info

### Internal
- [x] Background message receiver/dispatcher
- [x] Subscription tracking (Table[string, bool] for active subscriptions)
- [x] Handle incoming pub/sub events (command 0xFF)

## Implementation Order

1. **Phase 1: Protocol Types** (protocol.nim)
   - Add Command enums for pub/sub
   - Add PubSubMessageType enum
   - Add PubSubEvent type
   - Add SubscriptionOptions type

2. **Phase 2: Basic Subscribe/Publish** (protocol.nim + client.nim)
   - Implement subscribe encoding/decoding
   - Implement publish encoding/decoding
   - Add subscribe() method to client
   - Add publish() method to client
   - Add basic event receiving

3. **Phase 3: Message Handling** (client.nim)
   - Implement onMessage callback
   - Handle incoming 0xFF events
   - Add subscription tracking
   - Implement unsubscribe

4. **Phase 4: Query Methods** (protocol.nim + client.nim)
   - Implement listSubscribers
   - Implement listTopics
   - Implement getHistory
   - Implement getPresence

## Test Coverage

The test suite covers:
- ✓ Basic subscribe/unsubscribe
- ✓ Pattern subscriptions
- ✓ Publishing with different message types
- ✓ Receiving messages via callback
- ✓ Message filtering by type
- ✓ Listing subscribers and topics
- ✓ Message history retrieval
- ✓ Presence tracking
- ✓ Error handling
- ✓ Concurrent operations with multiple clients

Total: 34 test cases across 12 test suites
