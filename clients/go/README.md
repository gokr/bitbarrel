# BitBarrel Go Client

Go client library for BitBarrel key-value store with WebSocket protocol support.

## Features

- Full WebSocket protocol implementation (RFC 6455)
- All BitBarrel operations (GET, SET, DELETE, etc.)
- Barrel management
- Statistics support: Get comprehensive barrel statistics and metrics
- Context support for timeouts and cancellation
- Pub/Sub messaging (basic subscribe/publish implemented, query methods pending)

## Pub/Sub Messaging

BitBarrel provides real-time Pub/Sub messaging with topic-based subscriptions. The Go client currently supports basic subscribe/publish operations with event handling. Query methods (`ListSubscribers`, `GetHistory`, `GetPresence`, `ListTopics`) are pending implementation.

### Available Methods

**Subscription Management:**
- `Subscribe(topic string, opts SubscriptionOptions) (string, error)` - Subscribe to topic or pattern
- `SubscribeSimple(topic string) (string, error)` - Convenience wrapper for basic subscription
- `IsSubscribed(subId string) bool` - Check if subscription is active
- `Unsubscribe(subId string) (bool, error)` - Remove specific subscription
- `UnsubscribeAll() (int, error)` - Remove all subscriptions

**Publishing:**
- `Publish(topic string, msgType PubSubMessageType, payload string, headers string) (uint64, error)` - Publish message
- `PublishSimple(topic string, msgType PubSubMessageType, payload string) (uint64, error)` - Publish without headers
- `PublishData(topic string, payload string) (uint64, error)` - Publish data message (convenience)

**Event Handling:**
- `SetMessageHandler(handler func(PubSubEvent))` - Set callback for incoming Pub/Sub events
- `StartEventReceiver()` - Start background goroutine to receive events

**Pending Query Methods** (not yet implemented):
- `ListSubscribers(topic string) ([]SubscriptionInfo, error)`
- `GetHistory(topic string, req HistoryRequest) ([]PubSubEvent, error)`
- `GetPresence(topic string) (PresenceInfo, error)`
- `ListTopics() ([]string, error)`

### Example

```go
package main

import (
    "fmt"
    "github.com/tankfeed/bitbarrel-go"
)

func main() {
    client := bitbarrel.NewClient("localhost", 9876)
    client.Connect()
    defer client.Close()

    // Set up message handler
    client.SetMessageHandler(func(event bitbarrel.PubSubEvent) {
        fmt.Printf("Received event: topic=%s, payload=%s\n", event.Topic, event.Payload)
    })
    client.StartEventReceiver()

    // Subscribe to pattern
    subId, err := client.Subscribe("user:notifications:*", bitbarrel.SubscriptionOptions{})
    if err != nil {
        panic(err)
    }
    defer client.Unsubscribe(subId)

    // Publish message
    seq, err := client.PublishData("user:notifications:123", "Welcome to the system!")
    if err != nil {
        panic(err)
    }
    fmt.Printf("Published message with sequence: %d\n", seq)

    // Check subscription status
    if client.IsSubscribed(subId) {
        fmt.Println("Subscription is active")
    }
}
```

### Pub/Sub Event Types

- `PubSubMessageType.Data` (0) - Normal published messages
- `PubSubMessageType.Presence` (1) - Member join/leave notifications

See [Pub/Sub Protocol Specification](../../docs/PROTOCOL.md#pubsub-messaging) for complete details.

## Concurrency Model

**Important**: This client uses a **blocking/serialized** request model.

- Requests are processed sequentially - only one request can be in-flight at a time
- A mutex lock is held for the entire send-receive cycle to prevent interleaving
- Multiple goroutines can use the client safely, but requests will be serialized
- The sequence number is validated against responses but does not enable pipelining

This design ensures correctness and simplicity for most use cases. If you need high-throughput parallel requests, use multiple client instances (one per goroutine or connection pool).

**Example of concurrent-safe (but serialized) usage:**
```go
var wg sync.WaitGroup
for i := 0; i < 10; i++ {
    wg.Add(1)
    go func(n int) {
        defer wg.Done()
        // These calls will execute sequentially due to internal locking
        client.Set(fmt.Sprintf("key%d", n), fmt.Sprintf("val%d", n))
        client.Get(fmt.Sprintf("key%d", n))
    }(i)
}
wg.Wait()
```

**For parallel throughput**, use separate clients:
```go
// Create a client pool
clients := make([]*Client, 4)
for i := range clients {
    c := NewClient("localhost", 9876)
    c.Connect()
    clients[i] = c
    defer c.Close()
}

// Use different clients for parallel requests
```

## Installation

```bash
go get github.com/yourusername/bitbarrel-go
```

## Quick Start

```go.compilable
package main

import (
    "log"
    "github.com/yourusername/bitbarrel-go"
)

func main() {
    // Create client
    client := bitbarrel.NewClient("localhost", 9876)

    // Connect to server
    if err := client.Connect(); err != nil {
        log.Fatal("Failed to connect: ", err)
    }
    defer client.Close()

    // Create and use barrel
    if err := client.CreateBarrel("mydb", ""); err != nil {
        log.Fatal("Failed to create barrel: ", err)
    }

    if err := client.UseBarrel("mydb"); err != nil {
        log.Fatal("Failed to use barrel: ", err)
    }

    // Store data
    if err := client.Set("key", "value"); err != nil {
        log.Fatal("Failed to set: ", err)
    }

    // Retrieve data
    value, err := client.Get("key")
    if err != nil {
        log.Fatal("Failed to get: ", err)
    }

    log.Println("Retrieved:", value)
}
```

## Testing

The Go client includes comprehensive test suites for unit and integration testing.

### Run All Tests

```bash
cd clients/go
go test -v ./...
```

Unit tests run without a server. Integration tests require a BitBarrel server on `localhost:9876` and will automatically skip if not available.

### Run Specific Tests

Run a specific test by name:

```bash
go test -v -run TestIsValidCommand
go test -v -run TestRequestEncodeDecode
go test -v -run TestRangeQuery
```

### Run Integration Tests

Integration tests require a running BitBarrel server. Start the server first:

```bash
# From the bitbarrel root directory
./bitbarrel --port 9876
```

Then run the tests:

```bash
cd clients/go
go test -v ./...
```

Integration tests will skip with a message if the server is not available.

### Run Benchmarks

Run performance benchmarks:

```bash
go test -bench=. -benchmem
```

Specific benchmarks available:
- `BenchmarkRequestEncode` - request encoding performance
- `BenchmarkRequestDecode` - request decoding performance
- `BenchmarkResponseEncode` - response encoding performance
- `BenchmarkResponseDecode` - response decoding performance

### Test Coverage

Get code coverage report:

```bash
go test -cover -coverprofile=coverage.out
go tool cover -html=coverage.out
```

## Documentation

- [API Reference](https://pkg.go.dev/github.com/yourusername/bitbarrel-go)
- [Protocol Specification](../../../docs/PROTOCOL.md)

## Examples

See the [examples](examples/) directory for complete examples:
- [Basic operations](examples/basic/)
- [Barrel management](examples/barrels/)
- [Concurrent access](examples/concurrent/)

## License

MIT License - see LICENSE file for details
