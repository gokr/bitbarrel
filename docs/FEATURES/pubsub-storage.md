# Pub/Sub Storage Backends - Implementation Deep Dive

This document provides a comprehensive technical overview of BitBarrel's pluggable storage backend system for Pub/Sub message history.

## Architecture Overview

The storage backend system consists of five main components:

1. **StorageBackend Interface** - Abstract base for all storage implementations
2. **Storage Strategies** - Four concrete implementations (Memory, Shared, PerTopic, Hybrid)
3. **StorageConfig** - Configuration system with pattern-based routing
4. **StorageManager** - Lifecycle management and orchestration
5. **HistoryStoreV2 API** - High-level API for Pub/Sub integration

```
┌────────────────────────────────────────────────────────────┐
│                PubSubManager                               │
│  (Manages subscriptions, publishes messages)               │
└──────────────────────┬─────────────────────────────────────┘
                       │
┌──────────────────────▼─────────────────────────────────────┐
│              HistoryStoreV2 API                            │
│  - addToHistory(topic, data, headers)                     │
│  - getHistory(topic, limit, sinceSeq)                     │
└──────────────────────┬─────────────────────────────────────┘
                       │
┌──────────────────────▼─────────────────────────────────────┐
│            StorageManager                                  │
│  - Maps topics to backends                                 │
│  - Manages backend lifecycle                               │
│  - Provides statistics                                     │
└──────────────────────┬─────────────────────────────────────┘
                       │
        ┌──────────────┼──────────────┬──────────────┐
        │              │              │              │
┌───────▼──────┐ ┌────▼──────┐ ┌─────▼──────┐ ┌────▼──────┐
│ MemoryBackend│ │Shared     │ │ PerTopic   │ │  Hybrid   │
│              │ │Barrel     │ │   Barrel   │ │ (routes   │
│ (Volatile)   │ │ (Persist)  │ │  (Persist) │ │  via      │
│              │ │            │ │            │ │ patterns) │
└──────────────┘ └───────────┘ └────────────┘ └───────────┘
```

## StorageBackend Interface

All storage backends implement the `StorageBackend` interface:

```nim
type
  StorageBackend* = ref object of RootObj
    topic*: string

  StorageBackendObj* {.acyclic.} = object of RootObj
    topic*: string

method addToHistory*(backend: StorageBackend,
                     data: string,
                     headers: string): int64 {.base, gcsafe.}
  ## Add message to history, return sequence number

method getHistory*(backend: StorageBackend,
                   limit: int = 100,
                   sinceSeq: int64 = -1): seq[PubSubMessage] {.base, gcsafe.}
  ## Get message history for topic

method cleanupOldMessages*(backend: StorageBackend,
                          keepLast: int): int {.base, gcsafe.}
  ## Remove old messages, keeping last N

method getTotalMessageCount*(backend: StorageBackend): int64 {.base, gcsafe.}
  ## Get total messages stored for topic

method close*(backend: StorageBackend) {.base, gcsafe.}
  ## Close backend and release resources
```

## Storage Strategies

### 1. MemoryBackend - Volatile In-Memory Storage

**File:** `src/pubsub/memory_backend.nim`

**Characteristics:**
- Ring buffer per topic (fixed size)
- O(1) append and random access
- Atomic sequence numbering
- Thread-safe with per-topic lock

**Data Structure:**
```nim
type
  MemoryBackend* = ref object of StorageBackend
    lock*: Lock
    buffer*: seq[PubSubMessage]  # Ring buffer
    head*: int                   # Write position
    tail*: int                   # Read position
    count*: int                  # Current item count
    nextSeq*: int64              # Next sequence number
```

**Sequence Numbering:**
```
Sequence numbers are monotonically increasing per topic:
  - Start from 1 (first message)
  - Increment by 1 for each message
  - Wrap around when reaching int64.max

Message keys for retrieval: msg:{topic}:{padded_sequence}
  Example: msg:user:123:0000000001
```

**Performance:**
- Append: O(1) - atomic increment and array write
- History retrieval: O(n) - copy up to `limit` messages
- Memory usage: Fixed (maxMessagesPerTopic * avgMessageSize)

**Use Cases:**
- High-frequency chat messages
- Live feeds and real-time updates
- Ephemeral notifications
- Cache-like scenarios where durability is not required

**Configuration:**
```nim
var config = TopicStorageConfig(
  strategy: ssMemoryOnly,
  maxMessages: 1000,           # Ring buffer size
  memoryConfig: MemoryConfig(
    maxMessagesPerTopic: 1000
  )
)
```

### 2. SharedBarrelBackend - Single Persistent Barrel

**File:** `src/pubsub/shared_barrel_backend.nim`

**Characteristics:**
- Single BitBarrel file for all topics
- Uses `bmCritBit` mode for ordered storage (requires bmCritBit mode from initialization)
- Efficient prefix queries for topic history
- Configurable retention per topic
- Compression support

**Message Format:**
```
Key format: msg:{topic}:{padded_sequence}
  Example: msg:user:alerts:0000000421

Key structure enables efficient queries:
  - All messages for topic: prefixQuery("msg:user:alerts:")
  - Messages since sequence: rangeQuery("msg:user:alerts:0000000100", "msg:user:alerts:9999999999")
```

**Storage Layer:**
```nim
type
  SharedBarrelBackend* = ref object of StorageBackend
    barrel*: Barrel              # BitBarrel in bmCritBit mode
    lock*: Lock                  # Protects sequence numbers
    topicSequences*: Table[string, int64]  # Current seq per topic
    config*: TopicStorageConfig
```

**Topic Isolation:**
- All topics share same physical barrel file
- Logical isolation via key prefixing
- Independent sequence counters per topic
- Separate retention policies per topic

**Performance:**
- Append: O(log n) - CritBit tree insertion
- History query: O(k + log n) - k=matching keys
- Batch operations supported via `batchAddToHistory()`

**Advantages:**
- Single file for backup/archival
- Efficient cross-topic queries possible
- Lower file descriptor usage
- Shared cache benefits

**Disadvantages:**
- Single point of contention (all topics)
- Harder to isolate noisy neighbors
- Topic deletion requires scanning keys

**Use Cases:**
- General-purpose Pub/Sub with persistence needs
- Audit logs and compliance
- Message history with moderate scale
- Development and testing environments

### 3. PerTopicBarrelBackend - Separate Barrel per Topic

**File:** `src/pubsub/shared_barrel_backend.nim` (shares implementation with SharedBarrelBackend but creates separate instances per topic)

**Characteristics:**
- Independent barrel per topic
- Complete isolation between topics
- Independent compaction and recovery
- Higher resource usage (multiple files)

**Architecture:**
```
Topic: user:alice:notifications
Barrel: data/pubsub/user_alice_notifications.data

Topic: system:alerts
Barrel: data/pubsub/system_alerts.data
```

**Storage Manager Pattern:**
```nim
// StorageManager maintains map of topic → backend
var topicBackends: Table[string, StorageBackend]

proc getBackend(topic: string): StorageBackend =
  if topic notin topicBackends:
    # Create new backend for topic
    let backend = createPerTopicBackend(topic)
    topicBackends[topic] = backend
  return topicBackends[topic]
```

**Advantages:**
- True isolation between topics
- Independent performance characteristics
- Easier to delete topics (delete single file)
- Better concurrency (no shared locks)

**Disadvantages:**
- Higher resource usage (file descriptors)
- More complex backup strategy
- Slower startup (open more files)
- Inefficient for many small topics

**Performance:**
- Similar to SharedBarrelBackend per topic
- Better parallelism (no shared locks)
- More concurrent I/O possible

**Use Cases:**
- Multi-tenant applications needing isolation
- High-scale deployments (millions of topics)
- Topics with vastly different access patterns
- Compliance requirements for data separation

### 4. Storage Manager & Hybrid Configuration

**File:** `src/pubsub/storage_manager.nim`

**Responsibilities:**
- Topic-to-backend routing
- Backend lifecycle (lazy init, idle cleanup)
- Pattern matching and strategy selection
- Statistics aggregation
- Cleanup coordination

**Routing Logic:**
```nim
proc getBackendForTopic(topic: string): StorageBackend =
  # 1. Check pattern overrides (most specific first)
  for pattern, config in storageConfig.topicOverrides:
    if matchesPattern(topic, pattern):
      return getOrCreateBackend(topic, config)

  # 2. Use default strategy
  return getOrCreateBackend(topic, storageConfig.defaultStrategy)

proc matchesPattern(topic, pattern: string): bool =
  # Pattern: user:*:notifications
  # Topic:   user:alice:notifications
  # Returns: true
```

**Pattern Matching Algorithm:**
```
Pattern format: segment1:*:segment3:*:segmentN
- * matches exactly one entire segment
- No partial matches (user:*lice* doesn't work)
- Pattern segments must match topic segments

Comparison: O(min(patternSegments, topicSegments))
```

**Lazy Initialization:**
```nim
proc getOrCreateBackend(topic: string,
                       config: TopicStorageConfig): StorageBackend =
  let key = topic & $config.strategy

  if key notin activeBackends:
    let backend = case config.strategy
      of ssMemoryOnly:
        createMemoryBackend(topic, config)
      of ssSharedBarrel:
        createSharedBackend(topic, config)
      of ssPerTopicBarrel:
        createPerTopicBackend(topic, config)
      of ssHybrid: raiseAssert(false)  # Internal error

    activeBackends[key] = backend

  return activeBackends[key]
```

**Idle Backend Cleanup:**
```nim
proc cleanupIdleBackends(timeout: int) =
  # Track last access time per backend
  let now = epochTime()

  for key, backend in activeBackends:
    let lastAccess = backend.getLastAccessTime()
    if now - lastAccess > timeout:
      backend.close()
      activeBackends.del(key)
```

## Storage Configuration

**File:** `src/pubsub/storage_config.nim`

```nim
type
  StorageStrategy* = enum
    ssMemoryOnly      # In-memory ring buffer
    ssSharedBarrel    # Single barrel for all topics
    ssPerTopicBarrel  # Separate barrel per topic
    ssHybrid         # Pattern-based routing

  TopicStorageConfig* = object
    strategy*: StorageStrategy
    maxMessages*: int           # Per-topic retention
    compressionEnabled*: bool   # Use compression if supported
    memoryConfig*: MemoryConfig
    sharedBarrelConfig*: SharedBarrelConfig
    perTopicConfig*: PerTopicConfig

  StorageConfig* = object
    defaultStrategy*: StorageStrategy
    defaultConfig*: TopicStorageConfig
    topicOverrides*: seq[(string, TopicStorageConfig)]
    enableStats*: bool
    idleCleanupInterval*: int   # Seconds

proc initStorageConfig*(): StorageConfig =
  ## Initialize with sensible defaults
  result.defaultStrategy = ssSharedBarrel
  result.defaultConfig.maxMessages = 10000
  result.topicOverrides = @[]
  result.enableStats = true
  result.idleCleanupInterval = 300  # 5 minutes

proc setSharedBarrelConfig*(config: var StorageConfig,
                            path: string,
                            barrelConfig: BarrelConfig) =
  ## Configure shared barrel storage
  ## Note: Sets both defaultStrategy and defaultTopicConfig.strategy to ssSharedBarrel
  config.defaultStrategy = ssSharedBarrel
  config.sharedBarrelPath = path
  config.sharedBarrelConfig = barrelConfig
  config.defaultTopicConfig.strategy = ssSharedBarrel
  config.defaultTopicConfig.indexMode = barrelConfig.mode
```

### Pattern-Based Configuration

```nim
proc addTopicOverride*(config: var StorageConfig,
                      pattern: string,
                      topicConfig: TopicStorageConfig) =
  ## Add pattern-based configuration override
  config.topicOverrides.add((pattern, topicConfig))

proc getConfigForTopic*(config: StorageConfig,
                       topic: string): TopicStorageConfig =
  ## Find most specific matching configuration
  for (pattern, topicConfig) in config.topicOverrides:
    if matchesPattern(topic, pattern):
      return topicConfig
  return config.defaultConfig
```

## Message Flow

### Publishing a Message

```
Client → PubSubManager.publish(topic, data)
  ↓
Get backend for topic (StorageManager)
  ↓
Backend.addToHistory(data) → int64 sequence
  ↓
Publish to subscribers (PubSubManager)
  ↓
Return sequence number to client
```

**Sequence number generation:**
```nim
# Per-topic atomic counter
let seq = atomicInc(topicSequences[topic])
Backend.store(key="msg:{topic}:{padded_seq}", value=data)
```

### Retrieving History

```
Client → PubSubManager.getHistory(topic, sinceSeq)
  ↓
Get backend for topic
  ↓
Backend prefix/scan keys: "msg:{topic}:*"
  ↓
Filter: keySequence > sinceSeq
  ↓
Sort by sequence, limit results
  ↓
Return PubSubMessage seq[]
```

**Efficient history retrieval:**
```nim
# Using shared barrel with CritBit
topicKeyStart = "msg:" & topic & ":"
topicKeyEnd = "msg:" & topic & ":" & HIGH_VALUE

let keys = barrel.itemsWithPrefix(topicKeyStart, limit, cursor)
for (key, value) in keys:
  let seq = parseSeqFromKey(key)
  if seq > sinceSeq:
    result.add(PubSubMessage(seq: seq, data: value))
```

### Storage Backend Selection Flow

```
Topic: "user:alice:notifications"
  ↓
Check topicOverrides (ordered by specificity)
  - "*"? No
  - "user:*"? No
  - "user:*:notifications"? YES → use this config
  ↓
Create or get backend with matched config
  ↓
Return backend for operations
```

## Performance Characteristics

### MemoryBackend
- **Throughput**: ~500K messages/sec (append)
- **Latency**: < 1μs per message
- **Memory**: Fixed (maxMessages * avgMessageSize)
- **Recovery**: None (volatile)

### SharedBarrelBackend
- **Throughput**: ~100K messages/sec (append)
- **Latency**: ~10μs per message
- **Memory**: Dynamic (all keys in CritBit tree)
- **Recovery**: 40K+ keys/sec with hint file

### PerTopicBarrelBackend
- **Throughput**: ~100K messages/sec per topic
- **Latency**: ~10μs per message
- **Memory**: Sum of all topic barrel KeyDirs
- **Recovery**: 40K+ keys/sec per barrel
- **Parallelism**: Better (no shared locks)

### Storage Manager Overhead
- **Pattern matching**: O(k) where k = number of patterns
- **Backend lookup**: O(1) hash table
- **Idle cleanup**: O(n) scan every cleanupInterval

## Configuration Best Practices

### Small Scale (< 1000 topics, < 1M messages/day)
```nim
config.defaultStrategy = ssSharedBarrel
config.sharedBarrelConfig.maxMessages = 10000
config.idleCleanupInterval = 600  # 10 minutes
```

### Medium Scale (< 10K topics, < 10M messages/day)
```nim
# Hybrid: separate strategies by topic type
config.defaultStrategy = ssSharedBarrel

var chatConfig = TopicStorageConfig(
  strategy: ssMemoryOnly,
  maxMessages: 100
)
config.addTopicOverride("chat:*", chatConfig)

var userConfig = TopicStorageConfig(
  strategy: ssPerTopicBarrel,
  maxMessages: 1000
)
config.addTopicOverride("user:*:notifications", userConfig)
```

### Large Scale (> 10K topics, > 10M messages/day)
```nim
# Per-topic for isolation and scalability
config.defaultStrategy = ssPerTopicBarrel
config.perTopicConfig.basePath = "data/pubsub/"
config.perTopicConfig.compressionEnabled = true

# Only critical system events use shared barrel
var systemConfig = TopicStorageConfig(
  strategy: ssSharedBarrel,
  maxMessages: 100000
)
config.addTopicOverride("system:*", systemConfig)
```

## Monitoring and Statistics

**Storage Manager Stats:**
```nim
proc getStats*(manager: StorageManager): Table[string, BackendStats] =
  ## Per-topic statistics
  for topic, backend in manager.backends:
    result[topic] = BackendStats(
      strategy: backend.config.strategy,
      totalMessages: backend.getTotalMessageCount(),
      storageSize: backend.getStorageSize(),
      lastAccess: backend.getLastAccessTime()
    )

proc getTotalStats*(manager: StorageManager): AggregatedStats =
  ## Combined statistics across all topics
  var totalMessages = 0
  var totalStorage = 0

  for stat in manager.getStats().values:
    totalMessages += stat.totalMessages
    totalStorage += stat.storageSize

  return AggregatedStats(
    totalTopics: manager.backends.len,
    totalMessages: totalMessages,
    totalStorageSize: totalStorage
  )
```

**Health Monitoring:**
```nim
# Monitor backend health
proc checkBackendHealth(manager: StorageManager): seq[string] =
  for topic, backend in manager.backends:
    if not backend.isHealthy():
      result.add(topic)

# Monitor storage capacity
proc checkStorageCapacity(manager: StorageManager): seq[string] =
  let stats = manager.getStats()
  for topic, stat in stats:
    if stat.storageSize > 1_000_000_000:  # 1GB
      result.add(topic)
```

## Migration Strategies

### Strategy 1: Dual-Write Migration (Zero Downtime)

```nim
# Phase 1: Write to both old and new
var config = initStorageConfig()
config.defaultStrategy = ssHybrid

# Old backend (existing messages)
var oldConfig = TopicStorageConfig(strategy: ssMemoryOnly)
config.addTopicOverride("*", oldConfig)

# New backend (new messages)
var newConfig = TopicStorageConfig(strategy: ssSharedBarrel)
config.addTopicOverride("v2:*", newConfig)

# Phase 2: Migrate historical data
proc migrateTopic(manager: StorageManager, oldTopic, newTopic: string) =
  let oldMessages = manager.getBackend(oldTopic).getHistory(limit=1000000)
  for msg in oldMessages:
    manager.getBackend(newTopic).addToHistory(msg.data, msg.headers)

# Phase 3: Switch over
# Update consumers to use new topic pattern
# Decommission old backend
```

### Strategy 2: Incremental Migration

```nim
# Gradually migrate topics based on traffic patterns
proc migrateLowTrafficTopics(manager: StorageManager) =
  let stats = manager.getStats()
  for topic, stat in stats:
    # Migrate if < 1 message/hour
    if stat.lastAccess < epochTime() - 3600 and
       stat.messageRate < 1.0/3600:
      migrateTopic(topic, topic & "_migrated")
```

## Error Handling

**Backend Creation Failure:**
```nim
try:
  let backend = manager.getBackendForTopic(topic)
except StorageError as e:
  if e.msg.contains("disk full"):
    # Fallback to memory backend
    let fallback = createMemoryBackend(topic, memoryConfig)
    manager.forceBackend(topic, fallback)
```

**Corrupted Data Recovery:**
```nim
proc recoverBackend(backend: StorageBackend) =
  # Scan for corrupted messages
  let messages = backend.getHistory(limit=1000000)
  var validCount = 0

  for msg in messages:
    if not isCorrupted(msg):
      validCount.inc()
    else:
      # Log corruption, skip message
      echo "Corrupted message at sequence: ", msg.sequence

  echo "Recovered ", validCount, " valid messages"
```

## Security Considerations

**Topic Isolation:**
- Per-topic backends provide strongest isolation
- Shared backends rely on key prefixing for logical isolation
- Memory backends are not persisted (reduces data exposure risk)

**Access Control:**
```nim
# Implement topic-level access control in PubSubManager
proc checkPublishPermission(user: User, topic: string): bool =
  # Enforce namespace isolation
  if topic.startsWith("user:") and not topic.contains(user.id):
    return false
  return true
```

**Data Encryption:**
```nim
# Application-level encryption in backend wrapper
proc addToHistoryEncrypted(backend: StorageBackend,
                          data: string): int64 =
  let encrypted = encrypt(data, encryptionKey)
  return backend.addToHistory(encrypted)
```

## Testing

**Unit Tests:**
```nim
suite "Storage Backend Tests":
  test "MemoryBackend ring buffer":
    var backend = createMemoryBackend("test", config)

    # Fill buffer
    for i in 0..<100:
      discard backend.addToHistory(fmt"msg:{i}", "")

    # Verify oldest messages dropped
    let history = backend.getHistory(limit=1000)
    check history.len == config.maxMessages
    check parseInt(history[0].data) > 0  # Not "msg:0"

  test "SharedBarrelBackend persistence":
    var backend = createSharedBackend("test", config)
    let seq = backend.addToHistory("test", "")

    # Reopen backend
    backend.close()
    backend = createSharedBackend("test", config)

    # Verify message persisted
    let history = backend.getHistory(limit=10)
    check history.len == 1
    check history[0].sequence == seq
```

**Integration Tests:**
```nim
suite "Storage Manager Integration":
  test "Pattern matching":
    var config = initStorageConfig()
    var chatConfig = TopicStorageConfig(strategy: ssMemoryOnly)
    config.addTopicOverride("chat:*", chatConfig)

    var manager = StorageManager.new(config)

    # Test pattern matching
    let chatBackend = manager.getBackendForTopic("chat:general")
    check chatBackend.config.strategy == ssMemoryOnly

    let otherBackend = manager.getBackendForTopic("other:topic")
    check otherBackend.config.strategy == config.defaultStrategy
```

## Future Enhancements

1. **Tiered Storage**
   - Hot data in memory
   - Warm data in shared barrel
   - Cold data in object storage (S3, etc.)

2. **Replication**
   - Cross-region storage backend replication
   - Read replicas for query scaling

3. **Advanced Retention**
   - Time-based with size limits
   - Priority-based retention (keep important messages longer)
   - Tiered retention (compress old messages)

4. **Metrics Integration**
   - Prometheus metrics export
   - Grafana dashboards
   - Alerting rules

## Related Documentation

- [Pub/Sub User Guide](../USER_GUIDE/pubsub.md) - User-facing documentation
- [Query Hooks](./hooks.md) - Transform query results
- [Storage Backend Tests](../../tests/system/pubsub/test_storage_backends.nim) - Test examples
- [Examples](../../examples/pubsub/) - Complete working examples
