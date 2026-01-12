# BitBarrel Python Client

Python client for BitBarrel key-value storage using WebSocket connection.

## Concurrency Model

**Important**: This client uses a **blocking/serialized** request model.

- Requests are processed sequentially - only one request can be in-flight at a time
- A `threading.Lock` is held for the entire send-receive cycle to prevent interleaving
- Multiple threads can use the client safely via the lock, but requests will be serialized
- The sequence number is validated against responses but does not enable pipelining

This design ensures correctness and simplicity for most use cases. If you need high-throughput parallel requests, use multiple client instances.

**Example of concurrent-safe (but serialized) usage:**
```python.compilable
from concurrent.futures import ThreadPoolExecutor
from bitbarrel import Client

client = Client()
client.connect()
client.use_barrel("mydb")

def set_get(key, value):
    client.set(key, value)
    return client.get(key)

# These will execute sequentially due to internal locking
with ThreadPoolExecutor(max_workers=10) as executor:
    futures = []
    for i in range(10):
        f = executor.submit(set_get, f"key{i}", f"value{i}")
        futures.append(f)
    results = [f.result() for f in futures]
```

**For parallel throughput**, use separate clients:
```python
from concurrent.futures import ThreadPoolExecutor

def worker():
    client = Client()
    client.connect()
    client.use_barrel("mydb")
    # ... do work ...
    client.close()

# Run multiple workers in parallel
with ThreadPoolExecutor(max_workers=4) as executor:
    executor.map(lambda _: worker(), range(4))
```

## Features

- Full WebSocket protocol implementation
- All BitBarrel operations (GET, SET, DELETE, etc.)
- Barrel management
- Statistics support: Get comprehensive barrel statistics and metrics
- Context manager support for automatic resource cleanup
- Range and prefix queries with cursor-based pagination
- Reference traversal support
- Pub/Sub messaging (basic subscribe/publish implemented, query methods pending)
- Comprehensive test coverage

## Installation

The client requires Python >= 3.8 and the `websocket-client` library for WebSocket communication.

### Virtual Environment Setup

It is recommended to use a virtual environment:

```bash
# Create virtual environment
python3 -m venv venv

# Activate virtual environment
# On Linux/macOS:
source venv/bin/activate
# On Windows:
venv\Scripts\activate

# Install the package
pip install -e .
```

### Direct Installation

Without a virtual environment:

```bash
pip install -e .
```

## Quick Start

```python.compilable
from bitbarrel import Client

# Create client
client = Client()

# Connect to server
client.connect()

# Create a barrel
client.create_barrel("mydb")
client.use_barrel("mydb")

# Store data
client.set("key1", "value1")
client.set("key2", "value2")

# Retrieve data
value = client.get("key1")
print(value)  # "value1"

# Check existence
if client.exists("key1"):
    print("Key exists!")

# List keys
keys = client.list_keys()
print(keys)  # ["key1", "key2"]

# Close connection
client.close()
```

**Using context manager:**

```python.compilable
from bitbarrel import Client

with Client() as client:
    client.create_barrel("mydb")
    client.use_barrel("mydb")
    client.set("key1", "value1")
# Connection automatically closed
```

## API Reference

### Connection

```python
Client(host: str = "localhost", port: int = 9876,
        connect_timeout: float = 5.0, request_timeout: float = 3.0)
```

```python
client.connect()
client.close()
client.connected  # bool property
```

### Context Manager

The client supports the `with` statement for automatic resource cleanup:

```python
from bitbarrel import Client

with Client() as client:
    client.create_barrel("mydb")
    client.use_barrel("mydb")
    client.set("key1", "value1")
# Connection is automatically closed when exiting the context
```

### Barrel Management

```python
client.create_barrel(name: str, config: str = "") -> None
client.open_barrel(name: str) -> None
client.use_barrel(name: str) -> None
client.list_barrels() -> List[str]
client.close_barrel(name: Optional[str] = None) -> None
client.drop_barrel(name: str) -> None
client.get_barrel_config(name: str) -> str
client.set_barrel_config(name: str, config: str) -> None
client.current_barrel  # str property
```

### Key-Value Operations

```python
client.get(key: str) -> str
client.set(key: str, value: str) -> None
client.delete(key: str) -> None
client.exists(key: str) -> bool
client.count() -> int
client.list_keys() -> List[str]
client.ping() -> None
```

### Range Queries (requires bmCritBit mode barrel)

```python
# Query by range
result = client.range_query("user:1000", "user:2000", limit=100, cursor="")
print(result.items)       # List of (key, value) tuples
print(result.nextCursor)  # Cursor for next page
print(result.hasMore)     # True if more items available

# Query by prefix
result = client.prefix_query("user:", limit=100, cursor="")

# Count in range
count = client.range_count("user:1000", "user:2000")
```

### Keys-Only Queries

When you only need keys without values, use keys-only queries for better performance:

```python
# Range query for keys only (more efficient)
keys_result = client.range_query_keys("user:1000", "user:2000", limit=100)
print(keys_result.keys)  # List of keys only (no values)

# Prefix query for keys only
keys_result = client.prefix_query_keys("temp:", limit=1000)
```

**Benefits:**
- Lower network overhead (only keys transferred)
- Reduced memory usage
- Faster when values aren't needed
- Ideal for key enumeration and cleanup

### Iterator Helpers

For memory-efficient processing of large datasets:

```python
from bitbarrel.helpers import get_all_in_range, get_all_with_prefix

# Automatically paginates through all results
all_users = get_all_in_range(client, "user:0000", "user:9999")
for key, value in all_users:
    process_user(key, value)

# Process keys only (even more memory efficient)
temp_keys = client.prefix_query_keys("temp:", limit=10000)
for key in temp_keys.keys:
    if is_expired(key):
        client.delete(key)
```

### Reference Traversal

```python
# Traverse references
results = client.traverse(
    key="user:1",
    path_spec="->friend",
    include_full_data=True,
    extract_arrays=False,
    first_only=False
)

for r in results:
    print(f"{r.path}: {r.value}")

# Convenience method
results = client.traverse_path("user:1", "->friend")
```

## Pub/Sub Messaging

BitBarrel provides real-time Pub/Sub messaging with topic-based subscriptions. The Python client currently supports basic subscribe/publish operations with event handling. Query methods (`list_subscribers`, `get_history`, `get_presence`, `list_topics`) are pending implementation.

### Available Methods

**Subscription Management:**
- `subscribe(topic: str, options: SubscriptionOptions) -> str` - Subscribe to topic or pattern
- `subscribe_simple(topic: str) -> str` - Convenience wrapper for basic subscription
- `is_subscribed(sub_id: str) -> bool` - Check if subscription is active
- `unsubscribe(sub_id: str) -> bool` - Remove specific subscription
- `unsubscribe_all() -> int` - Remove all subscriptions

**Publishing:**
- `publish(topic: str, msg_type: PubSubMessageType, payload: str, headers: str = "") -> int` - Publish message
- `publish_simple(topic: str, msg_type: PubSubMessageType, payload: str) -> int` - Publish without headers
- `publish_data(topic: str, payload: str) -> int` - Publish data message (convenience)

**Event Handling:**
- `set_message_handler(handler: Callable[[PubSubEvent], None])` - Set callback for incoming Pub/Sub events
- `start_event_receiver()` - Start background thread to receive events
- `stop_event_receiver()` - Stop the background event receiver

**Pending Query Methods** (not yet implemented):
- `list_subscribers(topic: str) -> List[SubscriptionInfo]`
- `get_history(topic: str, req: HistoryRequest) -> List[PubSubEvent]`
- `get_presence(topic: str) -> PresenceInfo`
- `list_topics() -> List[str]`

### Example

```python.compilable
from bitbarrel import Client
from bitbarrel.protocol import PubSubMessageType, SubscriptionOptions

client = Client()
client.connect()

# Set up message handler
def on_message(event):
    print(f"Received event: topic={event.topic}, payload={event.payload}")

client.set_message_handler(on_message)
client.start_event_receiver()

# Subscribe to pattern
sub_id = client.subscribe("user:notifications:*", SubscriptionOptions())

# Publish message
seq = client.publish_data("user:notifications:123", "Welcome to the system!")
print(f"Published message with sequence: {seq}")

# Check subscription status
if client.is_subscribed(sub_id):
    print("Subscription is active")

# Clean up
client.unsubscribe(sub_id)
client.stop_event_receiver()
client.close()
```

### Pub/Sub Event Types

- `PubSubMessageType.DATA` (0) - Normal published messages
- `PubSubMessageType.PRESENCE` (1) - Member join/leave notifications

See [Pub/Sub Protocol Specification](../../docs/PROTOCOL.md#pubsub-messaging) for complete details.

## Helper Functions

The `bitbarrel.helpers` module provides convenience functions:

```python
from bitbarrel import Client
from bitbarrel.helpers import (
    paginate_range_result,
    get_all_with_prefix,
    batch_set,
)

client = Client()
client.connect()
client.use_barrel("mydb")

# Get all items with prefix
items = get_all_with_prefix(client, "user:")

# Batch set
batch_set(client, [("key1", "val1"), ("key2", "val2")])

# Paginate through results
def fetch_page(cursor):
    return client.prefix_query("user:", limit=100, cursor=cursor)

all_items = paginate_range_result(fetch_page)
```

## Error Handling

The client uses exception-based error handling:

```python
from bitbarrel import (
    BitBarrelError,
    ConnectionError,
    NotFoundError,
    NoBarrelError,
    BarrelExistsError,
    ServerError,
)

try:
    client.get("nonexistent")
except NotFoundError:
    print("Key not found")
except NoBarrelError:
    print("No barrel selected - use use_barrel() first")
except ConnectionError as e:
    print(f"Connection failed: {e}")
except BitBarrelError as e:
    print(f"BitBarrel error: {e}")
```

## License

MIT
