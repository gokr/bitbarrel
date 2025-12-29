# BitBarrel Go Client

Go client library for BitBarrel key-value store with WebSocket protocol support.

## Features

- Full WebSocket protocol implementation (RFC 6455)
- All BitBarrel operations (GET, SET, DELETE, etc.)
- Barrel management
- Context support for timeouts and cancellation

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

```go
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

### Run All Tests (Unit Tests Only)

Unit tests do not require a running server and can be run at any time:

```bash
cd clients/go/bitbarrel
go test -v
```

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
./bitbarrel --port 9876 serve

# Or if using nim directly
nim c -r src/cli/main.nim --port 9876 serve

```

Then run the integration tests with the `BITBARREL_TEST_SERVER` environment variable:

```bash
cd clients/go/bitbarrel
BITBARREL_TEST_SERVER=true go test -v
```

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
