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
```python
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

```python
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

```python
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
