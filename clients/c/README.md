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
- libwebsockets (recommended for production use)

#### Installing libwebsockets

**Debian/Ubuntu:**
```bash
sudo apt-get install libwebsockets-dev
```

**Fedora/RHEL:**
```bash
sudo dnf install libwebsockets-devel
```

**macOS (Homebrew):**
```bash
brew install libwebsockets
```

**From source:**
```bash
git clone https://github.com/warmcat/libwebsockets.git
cd libwebsockets
mkdir build && cd build
cmake ..
make -j$(nproc)
sudo make install
```

The library will use libwebsockets if available, falling back to a built-in WebSocket implementation otherwise.

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
config.url = "ws://localhost:9876/ws";
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
// Create a barrel (BM_HASH or BM_CRITBIT)
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

// List all barrels
char** barrels = NULL;
size_t barrel_count;
if (bb_list_barrels(client, &barrels, &barrel_count) == BB_OK) {
    for (size_t i = 0; i < barrel_count; i++) {
        printf("Barrel: %s\n", barrels[i]);
    }
    bb_free_string_array(barrels, barrel_count);
}

// Drop barrel
if (bb_drop_barrel(client, "mydb") != BB_OK) {
    fprintf(stderr, "Failed to drop barrel\n");
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

// List all keys in barrel
char** keys = NULL;
size_t key_count;
if (bb_list_keys(client, &keys, &key_count) == BB_OK) {
    for (size_t i = 0; i < key_count; i++) {
        printf("Key: %s\n", keys[i]);
    }
    bb_free_string_array(keys, key_count);
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

### Batch Operations

```c
// Batch set multiple key-value pairs
const char* keys[3] = {"key1", "key2", "key3"};
const char* values[3] = {"value1", "value2", "value3"};
size_t success_count;
if (bb_batch_set(client, keys, values, 3, &success_count) == BB_OK) {
    printf("Set %zu keys successfully\n", success_count);
}

// Batch get multiple values
const char* get_keys[3] = {"key1", "key2", "key3"};
char** values = NULL;
uint8_t* statuses = NULL;
size_t result_count;
if (bb_batch_get(client, get_keys, 3, &values, &statuses, &result_count) == BB_OK) {
    for (size_t i = 0; i < result_count; i++) {
        if (statuses[i] == 0) {  // STATUS_OK
            printf("%s = %s\n", get_keys[i], values[i]);
            free(values[i]);
        } else {
            printf("%s not found\n", get_keys[i]);
        }
    }
    free(values);
    free(statuses);
}

// Batch delete multiple keys
const char* del_keys[2] = {"key1", "key2"};
if (bb_batch_delete(client, del_keys, 2, &success_count) == BB_OK) {
    printf("Deleted %zu keys successfully\n", success_count);
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

- Range queries only work with barrels in bmCritBit mode
- Pub/Sub message persistence between reconnections is not implemented

## Integration with Zig

See the `clients/zig/` directory for Zig bindings that provide a safe, idiomatic API on top of this C library.

## Protocol Compliance

This implementation follows BitBarrel protocol v1.1:
- ✅ WebSocket transport (using libwebsockets)
- ✅ Binary protocol encoding
- ✅ Big-endian integers
- ✅ Barrel management commands
- ✅ Data operations (GET, SET, DELETE, EXISTS, COUNT, LIST_KEYS)
- ✅ Barrel management (CREATE, OPEN, USE, CLOSE, DROP, LIST)
- ✅ Range queries (RANGE_QUERY, PREFIX_QUERY)
- ✅ Pub/Sub (SUBSCRIBE, PUBLISH, UNSUBSCRIBE)
- ✅ Key watching
- ✅ Batch operations (BATCH_SET, BATCH_GET, BATCH_DELETE)

## Performance Considerations

- Fixed buffer sizes (64KB) for most operations
- No dynamic allocation in hot paths
- Reused buffers for encoding/decoding
- Thread-safe with minimal locking

## Testing

Run the test suite:

```bash
cd clients/c/build
ctest
```

For manual testing with a server:
```bash
# Terminal 1: Start server
./bitbarrel --server --port 9876

# Terminal 2: Run tests
cd clients/c/build
ctest -V
```

Test categories:
1. **Unit Tests**: Test encoding/decoding functions in isolation
2. **Integration Tests**: Test against a running BitBarrel server
3. **Compatibility Tests**: Verify against other client implementations

## Future Enhancements

- SSL/TLS verification
- Additional examples (Pub/Sub, benchmarks)
- Async callback API
- Connection resilience with automatic reconnection
- Health checking
