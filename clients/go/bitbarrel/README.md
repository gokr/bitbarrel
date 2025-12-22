# BitBarrel Go Client

Go client library for BitBarrel key-value store with WebSocket protocol support.

## Features

- Full WebSocket protocol implementation (RFC 6455)
- All BitBarrel operations (GET, SET, DELETE, etc.)
- Barrel management
- Connection pooling (planned)
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

## Documentation

- [API Reference](https://pkg.go.dev/github.com/yourusername/bitbarrel-go)
- [Protocol Specification](../../../docs/PROTOCOL.md)
- [Usage Guide](../../../docs/networking-guide.md)

## Examples

See the [examples](examples/) directory for complete examples:
- [Basic operations](examples/basic/)
- [Barrel management](examples/barrels/)
- [Concurrent access](examples/concurrent/)

## License

MIT License - see LICENSE file for details
