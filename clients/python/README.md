# BitBarrel Python Client

Python client for BitBarrel key-value storage using WebSocket connection.

## Installation

This package requires the [Nim compiler](https://nim-lang.org) to build the native extension.

### Prerequisites

1. Install Nim from https://nim-lang.org or via your package manager:
   ```bash
   # Ubuntu/Debian
   sudo apt install nim

   # macOS (with Homebrew)
   brew install nim

   # Windows
   # Download installer from https://nim-lang.org/install.html
   ```

2. Install nimpy (Nim package):
   ```bash
   nimble install nimpy
   ```

### Install the package

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

## API Reference

### Connection

```python
Client(host: str = "localhost", port: int = 9876, connect_timeout: int = 5000)
```

```python
client.connect()
client.close()
```

### Barrel Management

```python
client.create_barrel(name: str, config: str = "") -> bool
client.open_barrel(name: str) -> bool
client.use_barrel(name: str) -> bool
client.list_barrels() -> List[str]
client.close_barrel(name: str = "") -> bool
client.drop_barrel(name: str) -> bool
```

### Key-Value Operations

```python
client.get(key: str) -> str
client.set(key: str, value: str) -> bool
client.delete(key: str) -> bool
client.exists(key: str) -> bool
client.count() -> int
client.list_keys() -> List[str]
client.ping() -> bool
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
    pathSpec="->friend",
    includeFullData=True,
    extractArrays=False,
    firstOnly=False
)

for r in results:
    print(f"{r.path}: {r.value}")

# Convenience method
results = client.traverse_path("user:1", "->friend")
```

## Examples

See the `examples/` directory for more examples:

- `basic.py` - Basic CRUD operations
- `barrels.py` - Barrel management
- `range_queries.py` - Range and prefix queries
- `traversal.py` - Reference traversal

## Helper Functions

The `bitbarrel.helpers` module provides convenience functions:

```python
from bitbarrel import Client
from bitbarrel.helpers import get_all_with_prefix, batch_set

client = Client()
client.connect()
client.use_barrel("mydb")

# Get all items with prefix
items = get_all_with_prefix(client, "user:")

# Batch set
batch_set(client, [("key1", "val1"), ("key2", "val2")])
```

## License

MIT
