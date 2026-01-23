# BitBarrel - Bitcask-style Key/Value Store with Extras

BitBarrel is a high-performance key/value database built in Nim, using the Bitcask storage model at the core. Bitcask implies **append only updates** and keeping **keys with file offsets in memory** for really fast one-seek reads. BitBarrel goes beyond this model in several aspects and it can be used both compiled-in similar to Sqlite or as a traditional network server using a native threading model.

BitBarrel offers fast writes, efficient reads, and robust crash recovery. It offers a mix of key/value benefits (fast), range queries, batch operations, JSON document features like server side graph traversal, TTL support per key and last but not least - a builtin pubsub system including watchable keys. Given that it uses websockets it can also be used directly from frontends.

**Some Features:**
- Three index modes: hash‑based (O(1)), sorted CritBit trees (range queries), and two‑tier partitioned indexes for massive datasets
- Cursor-based pagination for efficient range queries and prefix searches without offset overhead
- Non-blocking background thread compaction — writes continue uninterrupted during background compaction
- Network enabled with WebSockets and basic REST APIs, plus clients for Nim, Go, Dart/Flutter, Python, TypeScript, C, and Zig
- JWT authentication with role-based access control (admin, readwrite, readonly) for secure network access
- Web Admin UI written in Flutter using the Dart client library
- Simple to use Docker container including Web Admin UI

## Quick Start

### Get started in 30 seconds

```nim
import bitbarrel

# Open a database with default settings
var db = openBarrel("myapp.db")

# Store some data
discard db.set("user:42:name", "Alice")
discard db.set("user:42:email", "alice@example.com")

# Retrieve it
echo "User name: ", db.get("user:42:name")

# Clean up
db.close()
```

**Installation:** `nimble install` • **Build:** `nimble build` • **Tests:** `nimble test`

## Advanced Examples Showcase

### Example 1: Range Queries with Cursor Pagination (Go)

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

    // Create barrel with CritBit mode for ordered keys
    client.CreateBarrel("metrics", "critbit")
    client.UseBarrel("metrics")

    // Store time-series data
    for i := 0; i < 1000; i++ {
        key := fmt.Sprintf("sensor:temp:%04d", i)
        value := fmt.Sprintf("%.1f", 20.0 + float64(i%20)*0.5)
        client.Set(key, value)
    }

    // Cursor-based pagination through range
    var allItems []bitbarrel.KeyValue
    cursor := ""

    for {
        items, nextCursor, hasMore, err := client.PrefixQuery("sensor:temp:", 100, cursor)
        if err != nil {
            panic(err)
        }

        allItems = append(allItems, items...)

        if !hasMore {
            break
        }
        cursor = nextCursor
    }

    fmt.Printf("Processed %d temperature readings\n", len(allItems))
}
```

### Example 2: Pub/Sub Messaging with Pattern Matching (Python)

```python
import asyncio
from bitbarrel import BitBarrelClient

async def main():
    # Connect to server with context manager
    async with BitBarrelClient("localhost", 9876) as client:
        await client.use_barrel("chat")

        # Subscribe to user notification patterns
        await client.subscribe("user:*:notifications")

        # Set up message handler
        def on_message(event):
            print(f"📨 {event.topic}: {event.payload}")

        client.on_message = on_message

        # Start receiving messages in background
        client.start_event_receiver()

        # Publish messages to matching topics
        await client.publish("user:alice:notifications", "Welcome to the platform!")
        await client.publish("user:bob:notifications", "You have a new message")

        # Wait for messages to be delivered
        await asyncio.sleep(0.1)

asyncio.run(main())
```

### Example 3: Graph Traversal with References (TypeScript)

```typescript
import { BitBarrelClient } from '@bitbarrel/client';

async function socialGraph() {
    const client = new BitBarrelClient({
        host: 'localhost',
        port: 9876,
        autoConnect: true
    });

    await client.createBarrel('social');
    await client.useBarrel('social');

    // Store users with friend relationships using _refs field
    const aliceData = {
        name: 'Alice',
        age: 30,
        _refs: {
            friends: ['user:bob', 'user:charlie'],
            posts: ['post:123', 'post:456']
        }
    };

    const bobData = {
        name: 'Bob',
        age: 28,
        _refs: {
            friends: ['user:alice'],
            posts: ['post:789']
        }
    };

    await client.set('user:alice', JSON.stringify(aliceData));
    await client.set('user:bob', JSON.stringify(bobData));

    // Traverse friend relationships
    const aliceFriends = await client.traversePath('user:alice', 'friends');
    console.log(`Alice has ${aliceFriends.length} friends:`);

    aliceFriends.forEach((friend: string) => {
        console.log(`  - ${friend}`);
    });

    // Find all connections (two-level traversal)
    const allConnections = await client.traverse('user:alice', 'friends/*/friends', {
        includeFullData: false,
        extractArrays: true
    });

    console.log(`Found ${allConnections.length} total connections in graph`);

    await client.close();
}

socialGraph().catch(console.error);
```

### Example 4: TTL, Batch Operations & Iterators (Nim)

```nim
import bitbarrel
import bitbarrel_client

# Local barrel with TTL support
var localDb = openBarrel("cache.db")
defer: localDb.close()

# Set keys with automatic expiration
discard localDb.set("session:abc123", "user_data", ttl=300)  # 5 minutes
discard localDb.set("temp:calculation", "result", ttl=60)      # 1 minute

# Network client for batch operations
var client = newClient("localhost", 9876.Port)
client.connect()
defer: client.close()

discard client.useBarrel("inventory")

# Batch set multiple items efficiently
let products = @[
  ("product:1:name", "Laptop"),
  ("product:1:price", "999.99"),
  ("product:2:name", "Phone"),
  ("product:2:price", "699.99"),
  ("product:3:name", "Tablet"),
  ("product:3:price", "499.99")
]

let successCount = client.setMany(products)
echo "Successfully stored ", successCount, " products"

# Use iterator for memory-efficient traversal of large datasets
echo "All products:"
for (key, value) in client.itemsWithPrefix("product:"):
  echo "  ", key, " = ", value

# Cursor-based pagination example
var cursor = ""
var allPrices: seq[float]

while true:
  let (items, nextCursor, hasMore) = client.prefixQuery("product:", limit=50, cursor=cursor)

  for (key, value) in items:
    if key.endsWith(":price"):
      allPrices.add(parseFloat(value))

  if not hasMore:
    break
  cursor = nextCursor

echo "Average price: ", allPrices.sum() / allPrices.len.float
```

## Client Libraries

BitBarrel provides client libraries in multiple languages for remote access via WebSocket, with JWT authentication support:

| Language | Status | Auth | Batch | TTL | Watch | Notes |
|----------|--------|------|-------|-----|-------|-------|
| Nim | ✅ Complete | ✅ | ✅ | ✅ | ✅ | Native implementation |
| Go | ✅ Complete | ✅ | ✅ | ✅ | ✅ | Native implementation |
| Python | ✅ Complete | ✅ | ✅ | ✅ | ✅ | Context manager support |
| Dart/Flutter | ✅ Complete | ✅ | ✅ | ✅ | ✅ | Mobile + Web compatible |
| TypeScript | ✅ Complete | ✅ | ✅ | ✅ | ✅ | Node.js + browser |
| C | ✅ Complete | ⚠️ | ✅ | ✅ | ✅ | Binary protocol client |
| Zig | ✅ Complete | ⚠️ | ✅ | ✅ | ✅ | Direct WebSocket using libwebsockets |

**All clients are 100% feature-complete as of 2026-01-21** • See individual client READMEs for detailed documentation.

## Performance Highlights

| Metric | Value | Context |
|--------|-------|---------|
| Write throughput (none sync) | ~188K ops/sec | Buffered, sequential writes |
| Write throughput (sync) | ~186K ops/sec | OS‑level durability |
| Write throughput (fsync) | ~9.1K ops/sec | Disk‑level durability |
| Read throughput | ~172K ops/sec | Random access via in‑memory index |
| Mixed workload (80% read) | ~137K ops/sec | Combined operations |
| Recovery speed | 40K+ keys/sec | With v2 hint files and incremental recovery |

*See [Performance Guide](docs/DEVELOPER_GUIDE/performance.md) for detailed measurements.*

## Docker Quick Start

### Run with Docker

```bash
docker run -d --name bitbarrel -p 8080:8080 -v bitbarrel-data:/data ghcr.io/gokr/bitbarrel:latest
```

*Access: Server at `ws://localhost:8080`, Web Admin at `http://localhost:8080/admin/` • [Full Docker Guide](docs/DOCKER.md)*

## Documentation

### Getting Started
- [Quick Setup](docs/GETTING_STARTED.md) - Installation and first steps
- [Tutorial](docs/USER_GUIDE/tutorial.md) - Comprehensive guide with examples
- [Examples Directory](examples/README.md) - Runnable example programs

### Advanced Features
- [Features Overview](FEATURES.md) - Barrel modes, compression, networking, and more
- [Pub/Sub Messaging](docs/USER_GUIDE/pubsub.md) - Real-time messaging guide
- [Network Guide](docs/networking-guide.md) - Client/server setup with JWT auth
- [Configuration Guide](docs/USER_GUIDE/configuration.md) - Tuning for your use case

### Developer Resources
- [Performance Guide](docs/DEVELOPER_GUIDE/performance.md) - Benchmarking and optimization
- [Testing Guide](docs/DEVELOPER_GUIDE/testing.md) - Test suite documentation
- [Architecture](docs/DEVELOPER_GUIDE/architecture.md) - System design
- [Roadmap](TODO.md) - Future enhancements and priorities

## License
MIT License