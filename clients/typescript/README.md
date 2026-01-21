# BitBarrel TypeScript Client

A TypeScript client library for [BitBarrel](https://github.com/bitbarrel/bitbarrel), a high-performance Bitcask-style key-value storage engine.

## Features

- 🚀 **High Performance**: Binary protocol with WebSocket transport
- 📝 **Type-Safe**: Full TypeScript support with comprehensive type definitions
- 🔒 **Authentication**: JWT-based authentication support
- 📦 **Multiple Operations**: Full CRUD operations, range queries, batch operations, and barrel management
- ⚡ **TTL Support**: Automatic key expiration with optional TTL parameter
- 📡 **Pub/Sub Messaging**: Real-time topic-based subscriptions with pattern matching (core subscribe/publish implemented)
- 🎯 **Error Handling**: Comprehensive error hierarchy with detailed messages
- ⚡ **Automatic Reconnection**: Auto-connect on first operation with configurable timeouts
- 📊 **Event-Driven**: EventEmitter-based architecture for connection events

## Installation

```bash
npm install @bitbarrel/client
```

## Quick Start

```typescript
import { BitBarrelClient } from '@bitbarrel/client';

const client = new BitBarrelClient({
  host: 'localhost',
  port: 9876,
  autoConnect: true, // Automatically connect on first operation
});

// Create and use a barrel
await client.createBarrel('mydb');
await client.useBarrel('mydb');

// Store data
await client.set('user:1', JSON.stringify({ name: 'Alice', age: 30 }));

// Retrieve data
const user = await client.get('user:1');
console.log(JSON.parse(user)); // { name: 'Alice', age: 30 }

// Clean up
await client.close();
```

## API Reference

### Creating a Client

#### Constructor

```typescript
const client = new BitBarrelClient(config);
// or
const client = new BitBarrelClient(host, port, token);
```

**Config Options:**

```typescript
interface ClientConfig {
  host?: string;           // Default: 'localhost'
  port?: number;           // Default: 9876
  connectTimeout?: number; // Connection timeout in ms (default: 5000)
  requestTimeout?: number; // Request timeout in ms (default: 30000)
  token?: string;          // JWT authentication token
  autoConnect?: boolean;   // Auto-connect on first operation (default: true)
}
```

#### Convenience Function

```typescript
import { createClient } from '@bitbarrel/client';

const client = createClient('localhost', 9876);
// or with token authentication
const client = createClient('localhost', 9876, 'your-jwt-token');
```

### Connection Management

#### `connect(): Promise<void>`

Establish a WebSocket connection to the BitBarrel server.

```typescript
await client.connect();
```

#### `close(): Promise<void>`

Close the connection gracefully.

```typescript
await client.close();
```

#### `isConnected(): boolean`

Check if the client is currently connected.

```typescript
if (client.isConnected()) {
  console.log('Connected to BitBarrel');
}
```

#### Events

The client emits events for connection state changes:

```typescript
client.on('connected', () => {
  console.log('Connected to server');
});

client.on('disconnected', () => {
  console.log('Disconnected from server');
});

client.on('error', (error) => {
  console.error('Error:', error);
});
```

### Barrel Management

#### `createBarrel(name: string, config?: string): Promise<boolean>`

Create a new barrel (database).

```typescript
await client.createBarrel('mydb');
```

#### `useBarrel(name: string): Promise<boolean>`

Select a barrel for subsequent operations.

```typescript
await client.useBarrel('mydb');
```

#### `listBarrels(): Promise<string[]>`

Get a list of all available barrels.

```typescript
const barrels = await client.listBarrels();
console.log(barrels); // ['mydb', 'logs', 'cache']
```

#### `dropBarrel(name: string): Promise<boolean>`

Delete a barrel and all its data.

```typescript
await client.dropBarrel('tempdb');
```

#### `getBarrelConfig(name: string): Promise<string>`

Get barrel configuration as JSON string.

```typescript
const config = await client.getBarrelConfig('mydb');
```

#### `setBarrelConfig(name: string, config: string): Promise<boolean>`

Set barrel configuration.

```typescript
await client.setBarrelConfig('mydb', '{"maxSize": "1GB"}');
```

#### `getBarrelStats(name: string): Promise<BarrelStats>`

Get statistics for a barrel.

```typescript
const stats = await client.getBarrelStats('mydb');
console.log(`Total keys: ${stats.totalKeys}`);
```

### Key-Value Operations

#### `set(key: string, value: string, ttl?: number): Promise<boolean>`

Store a key-value pair with optional TTL (Time To Live).

```typescript
// Store without expiration
await client.set('user:1', JSON.stringify({ name: 'Alice' }));
await client.set('total:visits', '1000');

// Store with TTL (key will expire after 3600 seconds = 1 hour)
await client.set('temp:session', 'abc123', 3600);

// Store with short TTL (key will expire after 60 seconds)
await client.set('cache:price', '19.99', 60);
```

**Parameters:**
- `key` - The key to store
- `value` - The value to store
- `ttl` (optional) - Time to live in seconds. If provided, the key will automatically expire after this many seconds.

#### `get(key: string): Promise<string>`

Retrieve a value by key. Throws `NotFoundError` if key doesn't exist.

```typescript
const user = await client.get('user:1');
console.log(JSON.parse(user)); // { name: 'Alice' }
```

#### `getOrDefault(key: string, defaultValue?: string): Promise<string>`

Retrieve a value by key with optional default.

```typescript
const visits = await client.getOrDefault('visits:2024', '0');
console.log(visits); // Returns '0' if key doesn't exist
```

#### `delete(key: string): Promise<boolean>`

Delete a key.

```typescript
await client.delete('temp:key');
```

#### `exists(key: string): Promise<boolean>`

Check if a key exists.

```typescript
if (await client.exists('user:1')) {
  console.log('User exists');
}
```

#### `count(): Promise<number>`

Get the total number of keys in the current barrel.

```typescript
const keyCount = await client.count();
console.log(`Keys in barrel: ${keyCount}`);
```

#### `listKeys(): Promise<string[]>`

Get all keys in the current barrel.

```typescript
const keys = await client.listKeys();
console.log(`First key: ${keys[0]}`);
```

### Batch Operations

Batch operations allow you to perform multiple operations in a single request, improving performance for bulk operations.

#### `batchSet(items: Array<[string, string]>): Promise<number>`

Store multiple key-value pairs in a single request.

```typescript
const items: Array<[string, string]> = [
  ['user:1', JSON.stringify({ name: 'Alice' })],
  ['user:2', JSON.stringify({ name: 'Bob' })],
  ['user:3', JSON.stringify({ name: 'Charlie' })],
];

const successCount = await client.batchSet(items);
console.log(`Successfully stored ${successCount} items`);
```

**Returns:** The number of items successfully stored.

#### `batchGet(keys: string[]): Promise<Array<[string, string]>>`

Retrieve multiple values by their keys in a single request.

```typescript
const keys = ['user:1', 'user:2', 'user:3'];
const items = await client.batchGet(keys);

for (const [key, value] of items) {
  console.log(`${key}: ${value}`);
}
// Note: Only found keys are returned. Keys that don't exist are omitted from the result.
```

**Returns:** An array of `[key, value]` pairs for all found keys.

#### `batchDelete(keys: string[]): Promise<number>`

Delete multiple keys in a single request.

```typescript
const keysToDelete = ['temp:1', 'temp:2', 'temp:3'];
const deletedCount = await client.batchDelete(keysToDelete);
console.log(`Successfully deleted ${deletedCount} keys`);
```

**Returns:** The number of keys successfully deleted.

### Range Queries

**Note:** Range queries require the barrel to be in `bmCritBit` mode (ordered index).

#### `rangeQuery(startKey: string, endKey: string, options?): Promise<RangeResult>`

Get key-value pairs in a range.

```typescript
const result = await client.rangeQuery('user:001', 'user:100', {
  limit: 50,
  cursor: '',
});

console.log(`Found ${result.items.length} items`);
console.log(`Has more: ${result.hasMore}`);
console.log(`Next cursor: ${result.nextCursor}`);

// Process results
for (const [key, value] of result.items) {
  console.log(`${key}: ${value}`);
}
```

#### `prefixQuery(prefix: string, options?): Promise<RangeResult>`

Get key-value pairs with a prefix.

```typescript
const result = await client.prefixQuery('product:', {
  limit: 100,
});

for (const [key, value] of result.items) {
  console.log(`${key}: ${value}`);
}
```

#### `rangeCount(startKey: string, endKey: string): Promise<number>`

Count keys in a range without fetching values.

```typescript
const count = await client.rangeCount('user:001', 'user:100');
console.log(`Users 001-100: ${count}`);
```

### Pagination

Range queries support cursor-based pagination:

```typescript
let cursor = '';
let allItems: Array<[string, string]> = [];

while (true) {
  const { items, nextCursor, hasMore } = await client.rangeQuery(
    'user:001',
    'user:999',
    {
      limit: 100,
      cursor,
    }
  );

  allItems = allItems.concat(items);

  if (!hasMore) {
    break;
  }

  cursor = nextCursor;
}

console.log(`Loaded ${allItems.length} users`);
```

### Error Handling

The client throws specific error types that you can catch:

```typescript
import { NotFoundError, BarrelError, ConnectionError } from '@bitbarrel/client';

try {
  const value = await client.get('nonexistent');
} catch (error) {
  if (error instanceof NotFoundError) {
    console.log('Key does not exist');
  } else if (error instanceof BarrelError) {
    console.log('Barrel error:', error.message);
  } else if (error instanceof ConnectionError) {
    console.log('Connection error:', error.message);
  } else {
    console.error('Unexpected error:', error);
  }
}
```

**Error Classes:**

- `BitBarrelError` - Base error class
- `ConnectionError` - Connection-related errors
- `ProtocolError` - Protocol violations
- `RequestTimeoutError` - Request timeouts
- `BarrelError` - Barrel-specific errors
- `AuthenticationError` - Authentication failures
- `NotFoundError` - Key not found

### Reference Traversal

Traverse references between keys:

```typescript
// Store reference data
await client.set('order:1001', JSON.stringify({
  customer: 'customer:500',
  items: ['item:1', 'item:2'],
}));

// Traverse references
const results = await client.traverse('order:1001', 'customer->*', {
  includeFullData: true,
  extractArrays: true,
});

for (const result of results) {
  console.log(`Path: ${result.path}`);
  console.log(`Key: ${result.key}`);
  console.log(`Value: ${result.value}`);
}
```

### Utility Operations

#### `ping(): Promise<boolean>`

Check server connectivity.

```typescript
const isAlive = await client.ping();
if (isAlive) {
  console.log('Server is responding');
}
```

## Pub/Sub Messaging

BitBarrel provides real-time Pub/Sub messaging with topic-based subscriptions and pattern matching. The TypeScript client fully implements all Pub/Sub operations including subscriptions, publishing, history, presence, and topic management.

### Subscription Management

**Subscribe to topics:**
```typescript
// Subscribe with options
const subId = await client.subscribe('user:notifications:*', {
  enableKvEvents: false,
  enablePresence: true,
  replayHistory: 10, // Replay last 10 messages
});

// Simple subscription (default options)
const subId = await client.subscribeSimple('user:alice');
```

**Manage subscriptions:**
```typescript
// Check if subscription is active
if (client.isSubscribed(subId)) {
  console.log('Subscription active');
}

// Unsubscribe
await client.unsubscribe(subId);

// Unsubscribe all
const removed = await client.unsubscribeAll();
```

### Publishing Messages

**Publish messages:**
```typescript
// Publish with type and headers
const seq = await client.publish('user:notifications:123',
  PubSubMessageType.Data,
  'Welcome!',
  'priority=high'
);

// Publish data message (convenience)
const seq = await client.publishData('user:notifications:123', 'Welcome!');

// Publish presence notification
const seq = await client.publish('presence:room1',
  PubSubMessageType.Presence,
  '{"action": "join"}'
);
```

### Event Handling

**Set message handler:**
```typescript
// Set callback for incoming events
client.setMessageHandler((event: PubSubEvent) => {
  console.log(`Topic: ${event.topic}, Payload: ${event.payload}`);
});

// Or use EventEmitter
client.on('pubsub', (event: PubSubEvent) => {
  console.log(`Received event: ${event.topic}`);
});
```

### Example

```typescript
import { BitBarrelClient, PubSubMessageType } from '@bitbarrel/client';

async function pubSubExample() {
  const client = new BitBarrelClient();

  // Set up message handler
  client.setMessageHandler((event) => {
    console.log(`Received: ${event.topic} -> ${event.payload}`);
  });

  // Subscribe to pattern
  const subId = await client.subscribe('user:notifications:*', {
    replayHistory: 5,
  });

  // Publish message
  const seq = await client.publishData('user:notifications:123', 'Welcome!');
  console.log(`Published sequence: ${seq}`);

  // Check subscription status
  if (client.isSubscribed(subId)) {
    console.log('Subscription active');
  }

  // Clean up
  await client.unsubscribe(subId);
  await client.close();
}
```

### Pub/Sub Event Types

- `PubSubMessageType.Data` (0) - Normal published messages
- `PubSubMessageType.Presence` (1) - Member join/leave notifications

### Topic and History Queries

**List topics:**
```typescript
// Get all topics with activity info
const topics = await client.listTopics();
for (const topic of topics) {
  console.log(`${topic.name}: ${topic.messageCount} messages, ${topic.subscriberCount} subscribers`);
}
```

**Get message history:**
```typescript
// Get recent messages for a topic
const history = await client.getHistory('chat:room1', { limit: 50 });
for (const event of history) {
  console.log(`[${event.timestamp}] ${event.payload}`);
}

// Get messages since a specific sequence number
const newMessages = await client.getHistory('chat:room1', {
  limit: 100,
  sinceSeq: lastSeenSequence,
});
```

**List subscribers:**
```typescript
// Get all subscribers for a topic
const subscribers = await client.listSubscribers('chat:room1');
console.log(`${subscribers.length} subscribers`);
```

**Get presence info:**
```typescript
// Get presence information for a topic (requires enablePresence in subscription)
const presence = await client.getPresence('chat:room1');
console.log(`${presence.members.length} members online`);
for (const member of presence.members) {
  console.log(`Client ${member.clientId} joined at ${member.joinedAt}`);
}
```

See [Pub/Sub Protocol Specification](../../docs/PROTOCOL.md#pubsub-messaging) for complete details.

## Complete Example

```typescript
import { BitBarrelClient, NotFoundError } from '@bitbarrel/client';

async function main() {
  // Create client
  const client = new BitBarrelClient({
    host: 'localhost',
    port: 9876,
    autoConnect: true,
  });

  try {
    // Setup
    await client.createBarrel('ecommerce');
    await client.useBarrel('ecommerce');

    // Store products
    const products = [
      { id: '001', name: 'Laptop', price: 999.99 },
      { id: '002', name: 'Mouse', price: 29.99 },
      { id: '003', name: 'Keyboard', price: 79.99 },
    ];

    for (const product of products) {
      await client.set(`product:${product.id}`, JSON.stringify(product));
    }

    // Retrieve product
    const laptop = JSON.parse(await client.get('product:001'));
    console.log(`Laptop: $${laptop.price}`);

    // Store orders
    const order = {
      id: '1001',
      customer: 'customer:001',
      items: ['product:001', 'product:002'],
      total: 1029.98,
    };

    await client.set(`order:${order.id}`, JSON.stringify(order));

    // Check order exists
    if (await client.exists('order:1001')) {
      console.log('Order found!');
    }

    // Clean up
    await client.dropBarrel('ecommerce');

  } catch (error) {
    if (error instanceof NotFoundError) {
      console.log('Key not found');
    } else {
      console.error('Error:', error);
    }
  } finally {
    await client.close();
  }
}

main().catch(console.error);
```

## Advanced Usage

### Authentication

```typescript
const client = new BitBarrelClient({
  host: 'localhost',
  port: 9876,
  token: 'your-jwt-token',
});
```

### Custom Timeouts

```typescript
const client = new BitBarrelClient({
  host: 'localhost',
  port: 9876,
  connectTimeout: 10000, // 10 seconds
  requestTimeout: 60000, // 60 seconds
});
```

### Manual Connection Management

```typescript
const client = new BitBarrelClient({
  host: 'localhost',
  port: 9876,
  autoConnect: false, // Disable auto-connect
});

// Connect when ready
await client.connect();

// Use client...

// Disconnect when done
await client.close();
```

## Development

### Building

```bash
npm run build
```

### Running Tests

```bash
npm test                 # Run all tests
npm run test:coverage   # Run with coverage report
npm run test:watch      # Run in watch mode
```

### Running Examples

Basic example:
```bash
npm run build           # Compile TypeScript first
node examples/basic.js  # Run basic example
```

**Complete Dashboard Example:**

See the [dashboard example](./examples/dashboard/) for a full-stack real-time application demonstrating all BitBarrel features:

```bash
cd examples/dashboard
npm install
npm start
# Then open http://localhost:3000
```

This example includes:
- Real-time activity monitoring with WebSocket
- Time-based analytics with range queries
- User management with reference traversal
- Automatic data expiration with TTL
- Modern UI with smooth animations

## License

MIT License - see LICENSE file for details

## Contributing

Contributions are welcome! Please read the contributing guidelines in the main BitBarrel repository.
