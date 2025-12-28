# BitBarrel Dart/Flutter Client

A Dart/Flutter client library for [BitBarrel](../../), a high-performance Bitcask-style key-value store with WebSocket protocol support.

## Features

- Full WebSocket protocol implementation
- Cross-platform support: Android, iOS, and Flutter Web
- All BitBarrel operations: data CRUD, barrel management, range/prefix queries, reference traversal
- Cursor-based pagination for efficient large dataset operations
- Type-safe exception handling
- Comprehensive test coverage

## Installation

Add this package to your `pubspec.yaml`:

```yaml
dependencies:
  bitbarrel:
    path: ../bitbarrel/clients/dart
```

Or if published to pub.dev:

```yaml
dependencies:
  bitbarrel: ^1.0.0
```

Then run:

```bash
dart pub get
```

## Quick Start

```dart
import 'package:bitbarrel/bitbarrel.dart';

void main() async {
  final client = BitBarrelClient.localhost();

  try {
    // Connect to the server
    await client.connect();

    // Create a barrel (or use an existing one)
    await client.createBarrel('mydb');

    // Set the active barrel
    await client.useBarrel('mydb');

    // Store data
    await client.set('user:alice', '{"name":"Alice","age":30}');
    await client.set('user:bob', '{"name":"Bob","age":25}');

    // Retrieve data
    final alice = await client.get('user:alice');
    print('Alice: $alice');

    // Check if key exists
    final exists = await client.exists('user:alice');
    print('Exists: $exists');

    // List all keys
    final keys = await client.listKeys();
    print('Keys: $keys');

    // Count keys
    final count = await client.count();
    print('Total keys: $count');

  } on BitBarrelException catch (e) {
    print('BitBarrel error: $e');
  } finally {
    await client.close();
  }
}
```

## API Reference

### Connection

| Method | Description |
|--------|-------------|
| `connect()` | Connect to the BitBarrel server |
| `close()` | Close the connection |
| `isConnected` | Check if connected (getter) |

### Barrel Operations

| Method | Description |
|--------|-------------|
| `createBarrel(name, config)` | Create a new barrel |
| `openBarrel(name)` | Open a barrel server-side |
| `useBarrel(name)` | Set the active barrel for this session |
| `closeBarrel()` | Close the current barrel |
| `listBarrels()` | List all barrels |
| `dropBarrel(name)` | Delete a barrel and its data |
| `getBarrelConfig(name)` | Get barrel configuration as JSON string |
| `setBarrelConfig(name, config)` | Update barrel configuration |

### Data Operations

| Method | Description |
|--------|-------------|
| `set(key, value)` | Store a key-value pair |
| `get(key)` | Retrieve a value by key |
| `delete(key)` | Delete a key |
| `exists(key)` | Check if a key exists |
| `count()` | Get the number of keys in the current barrel |
| `listKeys()` | List all keys in the current barrel |
| `ping()` | Send a health check to the server |

### Query Operations

#### Range Query

Get key-value pairs in a key range (requires barrel with `bmCritBit` index mode):

```dart
final result = await client.rangeQuery('user:100', 'user:200', limit: 100);
print('Items: ${result.items}');
print('Next cursor: ${result.nextCursor}');
print('Has more: ${result.hasMore}');
```

#### Prefix Query

Get items with keys starting with a prefix:

```dart
final result = await client.prefixQuery('user:', limit: 100);
for (final item in result.items) {
  print('${item.key}: ${item.value}');
}
```

#### Cursor-Based Pagination

Paginate through large datasets efficiently:

```dart
var cursor = '';
do {
  final result = await client.prefixQuery('user:', limit: 100, cursor: cursor);

  for (final item in result.items) {
    processItem(item);
  }

  cursor = result.nextCursor;
} while (result.hasMore);
```

#### Range Count

Count items in a range:

```dart
final count = await client.rangeCount('user:100', 'user:200');
```

#### Reference Traversal

Traverse JSON references in stored values:

```dart
final results = await client.traverse(
  'user:1',
  '*->books->*',
  options: TraverseOptions(
    includeFullData: true,
    extractArrays: false,
  ),
);

for (final result in results) {
  print('Path: ${result.path}, Value: ${result.value}');
}
```

## Configuration

Create a client with custom configuration:

```dart
final client = BitBarrelClient(BitBarrelConfig(
  host: 'example.com',
  port: 8080,
  connectTimeout: Duration(seconds: 10),
  requestTimeout: Duration(seconds: 5),
  path: '/ws',
));
```

## Barrel Configuration (for Range Queries)

Range and prefix queries require a barrel with CritBit index mode. Pass JSON configuration when creating the barrel:

```dart
await client.createBarrel('mydb', '{"mode":"bmCritBit"}');
await client.useBarrel('mydb');

// Now range queries will work
final result = await client.rangeQuery('a', 'z');
```

## Exception Handling

All BitBarrel exceptions extend `BitBarrelException`:

```dart
try {
  final value = await client.get('nonexistent');
} on KeyNotFoundException catch (e) {
  print('Key not found: ${e.key}');
} on NoBarrelSelectedException {
  print('No barrel selected');
} on BarrelNotFoundException {
  print('Barrel not found');
} on BarrelExistsException {
  print('Barrel already exists');
} on TimeoutException {
  print('Operation timed out');
} on ConnectionException {
  print('Connection error');
} on BitBarrelException catch (e) {
  print('Other BitBarrel error: $e');
} catch (e) {
  print('Unexpected error: $e');
}
```

## Testing

### Run Unit Tests

Unit tests don't require a running server:

```bash
cd clients/dart
dart test test/protocol_test.dart
```

### Run Integration Tests

Integration tests require a running BitBarrel server:

```bash
# Terminal 1: Start the BitBarrel server
cd /path/to/bitbarrel
./bitbarrel server --port 9876

# Terminal 2: Run tests
cd clients/dart
dart test test/client_integration_test.dart
```

### Run All Tests

```bash
cd clients/dart
dart test
```

## Example

Run the basic example:

```bash
cd clients/dart
dart run example/basic_example.dart
```

## Protocol Reference

The client implements the BitBarrel WebSocket protocol with the following format:

### Request Format
```
[cmd:1][seq:4][keyLen:2][key:N][valLen:4][value:M]
```

All multi-byte integers use big-endian encoding.

### Response Format
```
[status:1][seq:4][valLen:4][value:N]
```

### Protocol Limits

- Max Key Size: 65,535 bytes (64KB)
- Max Value Size: 33,554,432 bytes (32MB)

## Cross-Platform Notes

### Flutter Web

On Flutter Web, WebSocket connections must use `wss://` (secure) when served over HTTPS. The `web_socket_channel` package handles this automatically.

### Mobile (iOS/Android)

The client uses the native WebSocket implementation on each platform via `web_socket_channel`.

## Development

### Install Dependencies

```bash
cd clients/dart
dart pub get
```

### Run Tests

```bash
dart test
```

### Run Example

```bash
dart run example/basic_example.dart
```

### Format Code

```bash
dart format .
```

### Analyze Code

```bash
dart analyze
```

## License

MIT License - see the BitBarrel project LICENSE file for details.
