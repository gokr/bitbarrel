# BitBarrel Go Client

Go client library for BitBarrel key-value store with WebSocket protocol support.

## Features

- Full WebSocket protocol implementation (RFC 6455)
- All BitBarrel operations (GET, SET, DELETE, etc.)
- Barrel management
- Context support for timeouts and cancellation

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
# From the bitbarrel root directory (using the nim binary)
./bitbarrel server --port 9876

# Or if using nim directly
nim c -r src/cli/main.nim server --port 9876
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
