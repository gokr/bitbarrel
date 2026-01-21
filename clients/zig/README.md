# BitBarrel Zig Bindings

Native Zig bindings for the BitBarrel C client library, providing a safe and idiomatic API for Zig applications.

## Features

- Full Zig API wrapping the C client library
- Automatic memory management with Zig allocators
- Error handling using Zig error types
- Optional async support (planned)
- Type-safe wrappers for all BitBarrel operations

## Building

### Requirements

- Zig 0.11.0 or higher
- BitBarrel C library (built and installed)
- OpenSSL development libraries
- POSIX threads

### Current Status

**✅ Feature Complete (2026-01-21)**

The Zig client library is now fully feature-complete with:
- ✅ Basic KV operations (get, set, delete, exists, count)
- ✅ Batch operations (batchSet, batchGet, batchDelete)
- ✅ TTL support (setWithTtl)
- ✅ Barrel management (create, open, use, close, list, drop)
- ✅ Range queries (itemsInRange, itemsWithPrefix)
- ✅ Pub/Sub operations (subscribe, publish, listSubscribers, listTopics, getHistory, getPresence)
- ✅ Key watching (watchKey, unwatchKey)
- ✅ Memory-safe API with proper resource management
- ✅ Comprehensive integration test suite

### Build Instructions

To build the Zig bindings:

```bash
# Build the library
zig build

# Run tests
zig build test

# Build examples
zig build -Dexample=true
```

### Dependencies

The Zig bindings depend on the BitBarrel C library. Ensure it's built and available:

```bash
# Build and install C library first
cd ../c
mkdir build && cd build
cmake ..
make
sudo make install
sudo ldconfig  # On Linux
```

## Usage

Add BitBarrel to your `build.zig`:

```zig
const bitbarrel = @import("bitbarrel");

pub fn build(b: *std.Build) void {
    // Your build configuration
    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Link BitBarrel
    exe.linkSystemLibrary("bitbarrel");
    exe.linkLibC();

    // Add module
    exe.addModule("bitbarrel", bitbarrel.module("bitbarrel"));
}
```

## API Usage

### Basic Example

```zig
const std = @import("std");
const bitbarrel = @import("bitbarrel");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create client
    var client = try bitbarrel.Client.init(allocator, .{
        .url = "ws://localhost:7687",
        .timeout_ms = 5000,
    });
    defer client.deinit();

    std.debug.print("Connected: {}\n", .{client.isConnected()});

    // Create and open barrel
    try client.createBarrel("test", .hash);
    try client.openBarrel("test");
    try client.useBarrel("test");

    // Store data
    try client.set("name", "Alice");
    try client.set("age", "30");

    // Retrieve data
    if (try client.get("name")) |value| {
        std.debug.print("Name: {s}\n", .{value});
    }

    // Count keys
    const count = try client.count();
    std.debug.print("Keys in barrel: {}\n", .{count});
}
```

### Configuration

```zig
const config = bitbarrel.Config{
    .url = "ws://localhost:7687",      // WebSocket URL
    .timeout_ms = 5000,                // Request timeout
    .max_retries = 3,                  // Max reconnect attempts
    .enable_auto_reconnect = true,     // Auto-reconnect on connection loss
};

var client = try bitbarrel.Client.init(allocator, config);
defer client.deinit();
```

### Barrel Management

```zig
// Create barrel with specific mode
try client.createBarrel("mydb", .critbit);  // For range queries

// Open existing barrel
try client.openBarrel("mydb");

// Use barrel for operations
try client.useBarrel("mydb");

// List all barrels
const barrels = try client.listBarrels();
defer barrels.deinit();

for (barrels.items) |barrel| {
    std.debug.print("Barrel: {s}\n", .{barrel});
}

// Close barrel
try client.closeBarrel();
```

### Range Queries

Range queries work with barrels created in `critbit` mode:

```zig
// Create critbit barrel for range queries
try client.createBarrel("ordered", .critbit);
try client.useBarrel("ordered");

// Add some ordered data
try client.set("user:001", "Alice");
try client.set("user:002", "Bob");
try client.set("user:003", "Charlie");

// Query range
const start = "user:001";
const end = "user:003";
const limit = 100;

var result = try client.itemsInRange(start, end, limit, null);
defer result.deinit();

std.debug.print("Found {} items\n", .{result.items.items.len});
for (result.items.items) |item| {
    std.debug.print("{s} = {s}\n", .{item.key, item.value});
}

// Prefix queries
var prefix_result = try client.itemsWithPrefix("user:", limit, null);
defer prefix_result.deinit();

// Cursor-based pagination
if (prefix_result.next_cursor) |cursor| {
    var next_page = try client.itemsWithPrefix("user:", limit, cursor);
    defer next_page.deinit();
}
```

### Pub/Sub Operations

```zig
// Subscribe to topic
try client.subscribe("events");

// Publish messages
try client.publish("events", "User logged in");
try client.publish("events", "Data updated");

// Receive messages
var msg = client.pollMessage();
if (msg) |m| {
    std.debug.print("[{s}] {s}\n", .{m.topic(), m.data()});
    m.deinit();
}

// Wait for message with timeout
msg = try client.waitMessage(5000);  // 5 second timeout
if (msg) |m| {
    std.debug.print("Received: {s}\n", .{m.data()});
    m.deinit();
}

// Unsubscribe
try client.unsubscribe("events");
```

### Message Type

```zig
const msg = try client.waitMessage(5000);
if (msg) |message| {
    defer message.deinit();

    std.debug.print("Topic: {s}\n", .{message.topic()});
    std.debug.print("Data: {s}\n", .{message.data()});
    std.debug.print("Timestamp: {}\n", .{message.timestamp()});

    if (message.id()) |id| {
        std.debug.print("ID: {s}\n", .{id});
    }
}
```

### Error Handling

The API uses Zig's error handling mechanism:

```zig
// All operations return !T or Error!T
const value = client.get("key") catch |err| {
    switch (err) {
        Error.BarrelNotFound => std.debug.print("Barrel not found\n", .{}),
        Error.ConnectionError => std.debug.print("Connection error\n", .{}),
        Error.Timeout => std.debug.print("Operation timed out\n", .{}),
        else => std.debug.print("Error: {}\n", .{err}),
    }
    return;
};
```

## Modules

The Zig bindings are organized into modules:

- `bitbarrel`: Main client API
- `bitbarrel-errors`: Error types and utilities
- `bitbarrel-message`: Message types for Pub/Sub and range queries

## Memory Management

The Zig bindings handle memory automatically using the provided allocator:

```zig
// Strings and arrays are properly managed
const barrels = try client.listBarrels();
defer barrels.deinit();  // Frees all memory

// Messages are allocated and freed properly
const msg = try client.waitMessage(5000);
if (msg) |m| {
    defer m.deinit();  // Frees message memory
    // Use message
}
```

## Thread Safety

The Zig client is thread-safe, but each client instance should be used by one thread at a time. Create separate client instances for concurrent access from multiple threads.

## Integration Example

Here's a complete example integrating with a Zig application:

```zig
const std = @import("std");
const bitbarrel = @import("bitbarrel");

const Config = struct {
    db_url: []const u8,
    db_name: []const u8,
};

const Database = struct {
    client: bitbarrel.Client,
    name: []const u8,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Database {
        var client = try bitbarrel.Client.init(allocator, .{
            .url = config.db_url,
        });
        errdefer client.deinit();

        try client.createBarrel(config.db_name, .hash);
        try client.openBarrel(config.db_name);
        try client.useBarrel(config.db_name);

        return .{
            .client = client,
            .name = config.db_name,
        };
    }

    pub fn deinit(self: *Database) void {
        self.client.closeBarrel() catch {};
        self.client.deinit();
    }

    pub fn getUser(self: *Database, id: u64) !?[]const u8 {
        const key = try std.fmt.allocPrint(self.client.allocator, "user:{}", .{id});
        defer self.client.allocator.free(key);
        return try self.client.get(key);
    }

    pub fn setUser(self: *Database, id: u64, name: []const u8) !void {
        const key = try std.fmt.allocPrint(self.client.allocator, "user:{}", .{id});
        defer self.client.allocator.free(key);
        try self.client.set(key, name);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var db = try Database.init(allocator, .{
        .db_url = "ws://localhost:7687",
        .db_name = "myapp",
    });
    defer db.deinit();

    try db.setUser(1, "Alice");
    if (try db.getUser(1)) |name| {
        std.debug.print("User 1: {s}\n", .{name});
    }
}
```

## Differences from C API

The Zig bindings provide:

1. **Memory Safety**: Automatic memory management with allocators
2. **Type Safety**: Strong typing with Zig's type system
3. **Error Handling**: Idiomatic Zig error handling instead of error codes
4. **Resource Management**: `defer` and `errdefer` for cleanup
5. **Optional Types**: `?T` for nullable values instead of null pointers
6. **Slices**: Zig slices instead of C strings and arrays

## Building with Different Targets

Cross-compile to different targets:

```bash
# For Linux
cd clients/zig
zig build -Dtarget=x86_64-linux

# For macOS
zig build -Dtarget=aarch64-macos

# For Windows
zig build -Dtarget=x86_64-windows
```

## Troubleshooting

### "bitbarrel library not found"

Ensure the C library is installed:
```bash
cd clients/c
sudo make install
sudo ldconfig
```

### SSL/TLS errors

If using `wss://` URLs, ensure OpenSSL is installed:
```bash
# Ubuntu/Debian
sudo apt-get install libssl-dev

# macOS
brew install openssl
```

### Connection timeouts

Check that the BitBarrel server is running:
```bash
# In the main BitBarrel directory
./bitbarrel --server --port 7687
```

## Contributing

The Zig bindings are part of the main BitBarrel project. See the main README for contribution guidelines.

## Key Components

### 1. Client Wrapper (`src/client.zig")
- Zig wrapper around C client
- Automatic memory management with allocators
- Error translation from C to Zig errors
- Config struct with defaults
- Idiomatic Zig API

### 2. Error Handling (`src/errors.zig")
- Zig error types mapping to C error codes
- Error translation utilities
- Consistent error handling across the API

### 3. Message Types (`src/message.zig")
- Zig structs wrapping C message types
- Proper lifetime management
- Iterator support for range results

## Protocol Compliance

The Zig bindings implement BitBarrel protocol v1.1:
- ✅ WebSocket transport
- ✅ Binary protocol encoding
- ✅ Big-endian integers
- ✅ Barrel management commands
- ✅ Data operations (GET, SET, DELETE, etc.)
- ✅ Range queries
- ✅ Pub/Sub (SUBSCRIBE, PUBLISH)
- ✅ Key watching
- ✅ Batch operations (encoded but not fully exposed yet)

## Testing

Run the test suite:

```bash
cd clients/zig
zig build test
```

For integration testing with a server:
```bash
# Terminal 1: Start server
./bitbarrel --server --port 9876

# Terminal 2: Run tests
zig build test
```

## Performance Considerations

- Allocators allow custom memory management
- Result type avoids exceptions
- Iterator pattern for large result sets
- Proper cleanup with defer

## Future Enhancements

- Async I/O support
- Additional examples
- Connection pooling
- Batch operation helpers
- Streaming API for large results
- Additional integration tests

