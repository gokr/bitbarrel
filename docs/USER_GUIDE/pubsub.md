# Pub/Sub Messaging Guide

BitBarrel provides a comprehensive Pub/Sub (Publish/Subscribe) messaging system for real-time communication between clients. This guide covers everything you need to know to use Pub/Sub effectively.

## Overview

Pub/Sub messaging enables real-time communication through topic-based subscriptions. Clients can:

- **Subscribe** to exact topics or wildcard patterns
- **Publish** messages to topics
- **Receive** messages automatically when published
- **Track presence** of subscribers on topics
- **Retrieve message history** for topics with configurable retention
- **Receive key-value change events** when data in barrels changes

Pub/Sub is built into the BitBarrel server and available through the WebSocket protocol. Multiple client libraries provide native APIs for Pub/Sub operations.

## Topics and Patterns

### Topic Structure

Topics are hierarchical strings using colon-separated segments (e.g., `user:notifications:123`). There are no restrictions on topic format, but we recommend using consistent naming conventions.

Examples:
- `user:notifications:alice`
- `room:chat:general`
- `system:alerts:high`
- `presence:room:lobby`

### Pattern Matching

BitBarrel supports Redis-style glob patterns for subscriptions:

- `*` matches any characters within a segment
- Patterns only work within individual segments (`user:*:events` is invalid)
- Use `*` at the end for prefix matching (`user:notifications:*`)

**Valid patterns:**
- `user:notifications:*` - Matches all user notifications
- `room:*` - Matches all rooms
- `system:*` - Matches all system topics

**Invalid patterns:**
- `user:*:events` - `*` cannot be in the middle
- `*:notifications` - `*` cannot be at the beginning

### Topic Best Practices

1. **Use consistent naming**: Establish clear conventions (e.g., `entity:action:id`)
2. **Keep topics meaningful**: Topics should describe the data flow
3. **Consider scalability**: Avoid overly broad patterns that match too many topics
4. **Plan for permissions**: Structure topics to align with access control needs

## Subscribing to Messages

### Subscription Options

When subscribing, you can configure several options:

```nim
# Nim client example
let options = SubscriptionOptions(
  enableKvEvents: false,      # Receive key-value change events
  enablePresence: true,       # Receive presence notifications
  replayHistory: 10          # Replay last N messages on subscribe
)
let subId = client.subscribe("user:notifications:*", options)
```

**Options explained:**

- `enableKvEvents`: When true, you'll receive `mtKvChange` events when keys in barrels change
- `enablePresence`: When true, you'll receive `mtPresence` events when subscribers join/leave
- `replayHistory`: Number of recent messages to deliver immediately upon subscription

### Subscription Lifecycle

1. **Subscribe**: Client sends subscription request, receives unique subscription ID
2. **Active**: Server delivers matching messages to client
3. **Unsubscribe**: Client can unsubscribe by ID or unsubscribe all
4. **Auto-cleanup**: Subscriptions are automatically removed when client disconnects

### Managing Subscriptions

```go
// Go client example
subId, err := client.Subscribe("user:*", bitbarrel.SubscriptionOptions{})
if err != nil {
    log.Fatal(err)
}

// Check if subscription is active
if client.IsSubscribed(subId) {
    fmt.Println("Subscription active")
}

// Unsubscribe specific subscription
client.Unsubscribe(subId)

// Unsubscribe all
count, _ := client.UnsubscribeAll()
fmt.Printf("Removed %d subscriptions\n", count)
```

## Publishing Messages

### Basic Publishing

```python
# Python client example
seq = client.publish_data("user:notifications:123", "Welcome to the system!")
print(f"Published message with sequence: {seq}")
```

### Message Types

BitBarrel supports three message types:

1. **Data messages** (`mtData`/`PubSubMessageType.DATA`): Normal published content
2. **Presence messages** (`mtPresence`/`PubSubMessageType.PRESENCE`): Member join/leave notifications
3. **Key-Value change messages** (`mtKvChange`): Generated when barrel data changes (server-side)

### Message Headers

Messages can include optional headers as key-value pairs:

```typescript
// TypeScript client example
const seq = await client.publish(
  'user:notifications:123',
  PubSubMessageType.Data,
  'Welcome!',
  'priority=high&source=system'
);
```

Headers are transmitted as a string in `key=value&key2=value2` format and are available in received events.

### Message Sequence Numbers

Each published message receives a unique, monotonically increasing sequence number per topic. Use sequence numbers for:

- **Ordering**: Messages are delivered in sequence order
- **Deduplication**: Detect duplicate processing
- **History retrieval**: Request messages since a specific sequence

## Message Types in Detail

### Data Messages (`mtData`)

Normal application messages. The payload can be any string data (JSON, text, binary encoded as base64, etc.).

```dart
// Dart client example
await client.publishData('room:chat:general', '{"text":"Hello everyone!"}');
```

### Presence Messages (`mtPresence`)

Automatically generated when clients subscribe/unsubscribe to topics (when `enablePresence` is true). The payload contains JSON with action and metadata:

```json
{
  "action": "join",
  "clientId": "client-123",
  "timestamp": 1678901234567,
  "username": "alice"
}
```

**Actions:**
- `join`: Client subscribed to the topic
- `leave`: Client unsubscribed from the topic
- `timeout`: Client disconnected without unsubscribing

### Key-Value Change Messages (`mtKvChange`)

Generated when key-value pairs change in barrels (when `enableKvEvents` is true). These are server-side events useful for building reactive applications.

Payload format:
```json
{
  "action": "set",
  "key": "user:profile:alice",
  "value": "{\"name\":\"Alice\"}",
  "timestamp": 1678901234567,
  "barrel": "users"
}
```

**Actions:**
- `set`: Key was set or updated
- `delete`: Key was deleted
- `expire`: Key expired (if TTL configured)

## Presence Tracking

### Getting Presence Information

```nim
# Nim client (when implemented)
let presence = client.getPresence("room:chat:general")
echo "Members in room: ", presence.members.len
for member in presence.members:
  echo "  - ", member.username, " (joined at: ", member.joinedAt, ")"
```

### Presence Member Information

Each presence member includes:
- `clientId`: Unique connection identifier
- `username`: Optional human-readable name
- `joinedAt`: Timestamp when subscription started
- `lastPing`: Last activity timestamp
- `metadata`: Custom JSON metadata provided at subscription

### Use Cases for Presence

1. **Chat rooms**: Show who's currently in the room
2. **Collaborative editing**: Track active editors
3. **Game lobbies**: Show players waiting
4. **Support queues**: Track available agents

## Message History

### Configuring History Retention

History retention is configured per-topic in the server configuration. Messages are retained based on:
- **Count limit**: Maximum number of messages per topic
- **Age limit**: Maximum age of messages
- **Size limit**: Maximum total size of messages

### Retrieving History

```python
# Python client (when implemented)
history = client.get_history("user:notifications:123",
                             HistoryRequest(limit=50, since_seq=1000))
for event in history:
    print(f"{event.sequence}: {event.payload}")
```

**History request options:**
- `limit`: Maximum number of messages to return (default: 100)
- `since_seq`: Start from sequence number (exclusive)
- `reverse`: Return messages in reverse chronological order

### History Replay on Subscribe

When subscribing with `replayHistory: N`, the server delivers the last N messages immediately after subscription. This ensures new subscribers catch up on recent activity.

## Key-Value Change Events

### Enabling KV Events

Enable KV events by setting `enableKvEvents: true` in subscription options:

```go
// Go client example
opts := bitbarrel.SubscriptionOptions{
    EnableKvEvents: true,
}
subId, _ := client.Subscribe("kv:changes:*", opts)
```

### Event Filtering

KV events are filtered by the subscription pattern:
- Subscribe to `kv:changes:*` for all changes
- Subscribe to `kv:changes:users:*` for user-related changes
- Subscribe to specific keys for granular monitoring

### Use Cases

1. **Real-time dashboards**: Update UI when underlying data changes
2. **Cache invalidation**: Invalidate caches when source data updates
3. **Audit logging**: Track all data modifications
4. **Integration pipelines**: Trigger downstream processing

## Client Examples

### Nim Client

```nim
import bitbarrel_client

var client = newClient("localhost", 9876.Port)
client.connect()

# Set up message handler
client.onMessage = proc(event: PubSubEvent) =
  echo "Received: ", event.topic, " -> ", event.payload

# Subscribe with options
let options = SubscriptionOptions(
  enableKvEvents: false,
  enablePresence: true,
  replayHistory: 5
)
let subId = client.subscribe("user:notifications:*", options)

# Publish message
let seq = client.publishData("user:notifications:123", "Welcome!")
echo "Published sequence: ", seq

# Clean up
client.unsubscribe(subId)
client.close()
```

### Go Client

```go
package main

import (
    "fmt"
    "github.com/yourusername/bitbarrel-go"
)

func main() {
    client := bitbarrel.NewClient("localhost", 9876)
    client.Connect()
    defer client.Close()

    // Set message handler
    client.SetMessageHandler(func(event bitbarrel.PubSubEvent) {
        fmt.Printf("Received: %s -> %s\n", event.Topic, event.Payload)
    })
    client.StartEventReceiver()

    // Subscribe
    subId, err := client.Subscribe("user:notifications:*", bitbarrel.SubscriptionOptions{})
    if err != nil {
        panic(err)
    }
    defer client.Unsubscribe(subId)

    // Publish
    seq, err := client.PublishData("user:notifications:123", "Welcome!")
    if err != nil {
        panic(err)
    }
    fmt.Printf("Published sequence: %d\n", seq)
}
```

### Python Client

```python
from bitbarrel import Client
from bitbarrel.protocol import PubSubMessageType, SubscriptionOptions

client = Client()
client.connect()

def on_message(event):
    print(f"Received: {event.topic} -> {event.payload}")

client.set_message_handler(on_message)
client.start_event_receiver()

# Subscribe
sub_id = client.subscribe("user:notifications:*", SubscriptionOptions())

# Publish
seq = client.publish_data("user:notifications:123", "Welcome!")
print(f"Published sequence: {seq}")

# Clean up
client.unsubscribe(sub_id)
client.stop_event_receiver()
client.close()
```

### TypeScript Client

```typescript
import { BitBarrelClient, PubSubMessageType } from '@bitbarrel/client';

async function pubSubExample() {
  const client = new BitBarrelClient();

  // Set up event listener
  client.on('pubsub', (event) => {
    console.log(`Received: ${event.topic} -> ${event.payload}`);
  });

  // Subscribe with history replay
  const subId = await client.subscribe('user:notifications:*', {
    replayHistory: 5,
  });

  // Publish message
  const seq = await client.publishData('user:notifications:123', 'Welcome!');
  console.log(`Published sequence: ${seq}`);

  // Unsubscribe
  await client.unsubscribe(subId);
  await client.close();
}
```

### Dart Client

```dart
import 'package:bitbarrel/bitbarrel.dart';

void main() async {
  final client = BitBarrelClient.localhost();
  await client.connect();

  // Subscribe (event handling pending in Dart client)
  final subId = await client.subscribe('user:notifications:*', SubscriptionOptions());

  // Publish
  final seq = await client.publishData('user:notifications:123', 'Welcome!');
  print('Published sequence: $seq');

  // Note: Event handling infrastructure pending in Dart client
  // client.onMessage = (event) { ... };

  await client.unsubscribe(subId);
  await client.close();
}
```

## Best Practices

### Performance Considerations

1. **Use patterns wisely**: Broad patterns (`*`) can match many topics and impact performance
2. **Limit history retention**: Keep history retention reasonable for your use case
3. **Batch publications**: When publishing many messages, consider batching at application level
4. **Monitor subscription counts**: Many active subscriptions consume server resources

### Reliability Patterns

1. **Sequence number tracking**: Store last processed sequence number for crash recovery
2. **Idempotent processing**: Design message handlers to handle duplicates safely
3. **Connection recovery**: Re-subscribe after reconnection (subscriptions don't persist across connections)
4. **Error handling**: Implement proper error handling for network issues

### Security Considerations

1. **Topic naming**: Avoid exposing sensitive data in topic names
2. **Access control**: Use server-side authorization to control publish/subscribe permissions
3. **Validation**: Validate message content before processing
4. **Rate limiting**: Implement client-side rate limiting to avoid overwhelming the server

## Troubleshooting

### Common Issues

**No messages received:**
1. Check subscription pattern matches published topics
2. Verify `onMessage` callback is set
3. Ensure event receiver is started (Go/Python clients)
4. Check client is connected and subscription succeeded

**Messages delayed:**
1. Check network latency
2. Verify server load
3. Check client processing isn't blocking event loop

**Subscription failures:**
1. Verify topic/pattern format is valid
2. Check client connection state
3. Verify server supports Pub/Sub (BitBarrel 1.0+)

**Presence not working:**
1. Ensure `enablePresence: true` in subscription options
2. Check multiple clients are subscribed to same topic
3. Verify presence tracking is enabled server-side

### Debugging Tips

1. **Enable logging**: Increase client and server log levels
2. **Test with simple patterns**: Start with exact topic subscriptions
3. **Verify protocol compatibility**: Ensure client and server versions match
4. **Use ping/pong**: Verify basic connectivity before Pub/Sub operations

## Protocol Reference

For complete protocol details, see [PROTOCOL.md](../PROTOCOL.md#pubsub-messaging).

### Command Summary

| Command | Code | Description |
|---------|------|-------------|
| SUBSCRIBE | 0x40 | Subscribe to topic/pattern |
| UNSUBSCRIBE | 0x41 | Unsubscribe by ID |
| PUBLISH | 0x42 | Publish message |
| LIST_SUBSCRIBERS | 0x43 | List subscribers for topic |
| HISTORY | 0x44 | Get message history |
| LIST_TOPICS | 0x45 | List all topics |
| PRESENCE | 0x46 | Get presence information |
| PUBSUB_EVENT | 0xFF | Push notification (server → client) |

### Client Support Status

| Client | Core Pub/Sub | Event Handling | Query Methods |
|--------|-------------|----------------|---------------|
| Nim | ✅ Phase 2 | ✅ Implemented | ⏳ Phase 4 pending |
| Go | ✅ Basic | ✅ Implemented | ⏳ Pending |
| Python | ✅ Basic | ✅ Implemented | ⏳ Pending |
| TypeScript | ✅ Full | ✅ Implemented | ⏳ Pending |
| Dart | ✅ Basic | ⏳ Pending | ⏳ Pending |

See individual client READMEs for detailed implementation status.

## Next Steps

- Explore [PROTOCOL.md](../PROTOCOL.md) for complete protocol specification
- Check client-specific documentation for API details
- Review [examples](../../demos/) for complete working examples
- Experiment with the [web admin](../../webadmin/) for visual Pub/Sub testing

Need help? Check the main [README](../../README.md) for support resources.