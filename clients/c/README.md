# BitBarrel C Client Library

A C client library for BitBarrel that implements the network protocol (v1.1), allowing C applications to connect to BitBarrel servers via WebSocket.

## Features

- Full BitBarrel protocol v1.1 support
- WebSocket-based communication
- Thread-safe operations
- Memory-efficient design
- Support for all BitBarrel operations:
  - Barrel management (create, open, use, close, list)
  - Key-value operations (set, get, delete, exists, count)
  - Range queries (for bmCritBit mode)
  - Pub/Sub messaging
  - Key watching

## Building

### Requirements

- CMake 3.10 or higher
- C99-compatible compiler
- OpenSSL (for SSL/TLS support)
- POSIX threads (pthread)

### Build Instructions

```bash
mkdir build && cd build
cmake ..
make
make test
sudo make install
```

### Build Options

- `BUILD_SHARED_LIBS`: Build shared libraries (default: ON)
- `BUILD_TESTS`: Build tests (default: ON)
- `BUILD_EXAMPLES`: Build examples (default: ON)

Example:
```bash
cmake -DBUILD_TESTS=OFF ..
```

## API Usage

### Initialization

```c
#include <bitbarrel.h>

// Initialize library (call once per process)
bb_init();

// Create default configuration
BBConfig config = bb_config_default();
config.url = "ws://localhost:7687";
config.timeout_ms = 5000;

// Create client
BBClient* client = bb_client_create(&config);
if (!client) {
    fprintf(stderr, "Failed to create client\n");
    return -1;
}

// Connect to server
if (bb_connect(client) != BB_OK) {
    fprintf(stderr, "Failed to connect: %s\n", bb_get_last_error(client));
    bb_client_destroy(client);
    return -1;
}
```

### Barrel Operations

```c
// Create a barrel
if (bb_create_barrel(client, "mydb", BM_HASH) != BB_OK) {
    fprintf(stderr, "Failed to create barrel\n");
}

// Open and use barrel
if (bb_open_barrel(client, "mydb") != BB_OK) {
    fprintf(stderr, "Failed to open barrel\n");
}

if (bb_use_barrel(client, "mydb") != BB_OK) {
    fprintf(stderr, "Failed to use barrel\n");
}
```

### Key-Value Operations

```c
// Set a key-value pair
if (bb_set(client, "key1", "value1", -1) != BB_OK) {
    fprintf(stderr, "Failed to set key\n");
}

// Get a value
char* value = bb_get(client, "key1");
if (value) {
    printf("Value: %s\n", value);
    bb_free_string(value);  // Must free returned strings
} else {
    printf("Key not found\n");
}

// Check if key exists
if (bb_exists(client, "key1")) {
    printf("Key exists\n");
}

// Delete a key
if (bb_delete(client, "key1") != BB_OK) {
    fprintf(stderr, "Failed to delete key\n");
}

// Count keys in barrel
int64_t count;
if (bb_count(client, &count) == BB_OK) {
    printf("Barrel has %ld keys\n", count);
}
```

### Range Queries

```c
// Get items in range (requires bmCritBit mode)
BBRangeResult* result;
if (bb_items_in_range(client, "user:100", "user:200", 100, "", &result) == BB_OK) {
    printf("Found %zu items\n", result->count);
    for (size_t i = 0; i < result->count; i++) {
        printf("%s = %s\n", result->keys[i], result->values[i]);
    }
    printf("Has more: %s\n", result->has_more ? "yes" : "no");
    if (result->next_cursor) {
        printf("Next cursor: %s\n", result->next_cursor);
    }
    bb_free_range_result(result);
}

// Prefix queries
if (bb_items_with_prefix(client, "user:", 100, "", &result) == BB_OK) {
    // Process results
    bb_free_range_result(result);
}
```

### Pub/Sub Operations

```c
// Subscribe to a topic
if (bb_subscribe(client, "events") != BB_OK) {
    fprintf(stderr, "Failed to subscribe\n");
}

// Publish a message
if (bb_publish(client, "events", "Hello, World!") != BB_OK) {
    fprintf(stderr, "Failed to publish\n");
}

// Poll for messages (non-blocking)
BBMessage* msg = bb_poll_message(client);
if (msg) {
    printf("Received: [%s] %s\n", msg->topic, msg->data);
    bb_free_message(msg);
}

// Wait for message (blocking with timeout)
msg = bb_wait_message(client, 5000);  // 5 second timeout
if (msg) {
    printf("Received: [%s] %s\n", msg->topic, msg->data);
    bb_free_message(msg);
}

// Unsubscribe
bb_unsubscribe(client, "events");
```

### Cleanup

```c
// Close barrel
bb_close_barrel(client);

// Disconnect
bb_disconnect(client);

// Destroy client
bb_client_destroy(client);

// Cleanup global state
bb_cleanup();
```

## Thread Safety

All BitBarrel client operations are thread-safe. Multiple threads can share the same client instance and perform concurrent operations.

## Memory Management

- All functions returning `char*` allocate memory that must be freed by the caller
- Use `bb_free_string()` to free strings
- Use `bb_free_string_array()` to free string arrays
- Use `bb_free_message()` to free Pub/Sub messages
- Use `bb_free_range_result()` to free range query results

## Error Handling

All functions return `BBResult` indicating success or failure. Use `bb_get_last_error()` to get a descriptive error message.

```c
BBResult result = bb_set(client, "key", "value", -1);
if (result != BB_OK) {
    fprintf(stderr, "Error: %s\n", bb_get_last_error(client));
}
```

## Limitations

- WebSocket client uses a simplified implementation without full WebSocket handshake
- SSL/TLS support is included but not fully tested
- Range queries only work with barrels in bmCritBit mode
- Pub/Sub message persistence between reconnections is not implemented

## Integration with Zig

See the `clients/zig/` directory for Zig bindings that provide a safe, idiomatic API on top of this C library.

## License

This library follows the same license as BitBarrel (check the main project LICENSE file).
