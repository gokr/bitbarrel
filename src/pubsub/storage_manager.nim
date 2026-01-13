## Storage Manager - Backend Lifecycle and Strategy Management
##
## Manages storage backend instances, handles strategy resolution per topic,
## and provides caching for performance. Supports dynamic backend creation.

import std/[tables, locks, times, sequtils, os]
import ../pubsub
import ./storage_backend
import ./storage_config
import ./memory_backend
import ./shared_barrel_backend

type
  StorageManager* = ref object
    ## Global storage configuration
    config*: StorageConfig

    ## Backend cache (topic -> backend)
    backends*: Table[string, HistoryStorageBackend]
    backendsLock*: Lock

    ## Shared barrel backend (singleton)
    sharedBackend*: SharedBarrelBackend

    ## Topic-to-backend mapping for hybrid mode
    topicBackendTypes*: Table[string, StorageStrategy]
    topicBackendLock*: Lock

    ## Cleanup timer for idle backends
    lastAccess*: Table[string, int64]  ## topic -> last access time (ms)
    accessLock*: Lock

    ## Cleanup timer reference
    cleanupTimer*: Thread[ptr StorageManager]
    cleanupRunning*: bool

proc newStorageManager*(config: StorageConfig): StorageManager =
  ## Create a new storage manager with given configuration
  ##
  ## Parameters:
  ##   - config: Storage configuration
  result = StorageManager(
    config: config,
    backends: initTable[string, HistoryStorageBackend](),
    backendsLock: Lock(),
    sharedBackend: nil,
    topicBackendTypes: initTable[string, StorageStrategy](),
    topicBackendLock: Lock(),
    lastAccess: initTable[string, int64](),
    accessLock: Lock(),
    cleanupTimer: nil,
    cleanupRunning: false
  )

proc initSharedBackend(manager: StorageManager) {.gcsafe.} =
  ## Initialize shared barrel backend if needed
  if manager.config.defaultStrategy == ssSharedBarrel or
     manager.config.defaultStrategy == ssHybrid:
    if manager.config.sharedBarrelPath.len > 0:
      # Use default config for shared barrel
      var barrelConfig = defaultBarrelConfig()
      barrelConfig.mode = bmCritBit  # Required for ordered queries
      manager.sharedBackend = newSharedBarrelBackend(
        manager.config.sharedBarrelPath,
        barrelConfig,
        manager.config.batchSize
      )

proc getOrCreateBackend(manager: StorageManager,
                       topic: string): HistoryStorageBackend {.gcsafe.} =
  ## Get cached backend for topic or create new one
  var backend: HistoryStorageBackend

  # Check cache first
  withLock manager.backendsLock:
    if topic in manager.backends:
      backend = manager.backends[topic]

      # Update last access time
      withLock manager.accessLock:
        manager.lastAccess[topic] = getTime().toUnix() * 1000

      return backend

  # Determine strategy for topic
  let strategy = manager.config.resolveStrategy(topic)

  # Create backend based on strategy
  case strategy
  of ssMemoryOnly:
    var topicConfig = manager.config.resolveTopicConfig(topic)
    backend = newMemoryStorageBackend(topicConfig.maxMessages)

  of ssSharedBarrel:
    # Lazy init shared backend
    if manager.sharedBackend.isNil:
      manager.initSharedBackend()

    if manager.sharedBackend.isNil:
      raise newException(ValueError, "Shared backend not configured")

    backend = manager.sharedBackend

  of ssPerTopicBarrel:
    var topicConfig = manager.config.resolveTopicConfig(topic)
    let barrelPath = manager.config.getTopicBarrelPath(topic)

    # Create barrel config from topic config
    var barrelConfig = defaultBarrelConfig()
    barrelConfig.mode = bmCritBit  # Required for ordered queries
    barrelConfig.writeBufferSize = 64 * 1024  # 64KB default
    barrelConfig.syncMode = smNone  # Can be overridden from topicConfig

    # Enable compression if configured
    if topicConfig.compressionEnabled:
      barrelConfig.compressionConfig = addr(CompressionConfig(
        enabled: true,
        algorithm: caLZ4,
        threshold: topicConfig.compressionThreshold
      ))

    backend = newSharedBarrelBackend(barrelPath, barrelConfig,
                                      manager.config.batchSize)

  of ssHybrid:
    # For hybrid, check if topic has explicit override
    withLock manager.topicBackendLock:
      if topic in manager.topicBackendTypes:
        let explicitStrategy = manager.topicBackendTypes[topic]

        # Handle based on explicit strategy
        case explicitStrategy
        of ssMemoryOnly, ssPerTopicBarrel:
          # Redirect to specific backend creation
          var tempConfig = manager.config
          tempConfig.defaultStrategy = explicitStrategy
          let tempManager = newStorageManager(tempConfig)
          return tempManager.getOrCreateBackend(topic)
        else:
          discard

      # Default to shared backend for hybrid
      if manager.sharedBackend.isNil:
        manager.initSharedBackend()

      if manager.sharedBackend.isNil:
        raise newException(ValueError, "Shared backend not configured")

      backend = manager.sharedBackend

  # Cache the backend
  withLock manager.backendsLock:
    manager.backends[topic] = backend

    # Update last access time
    withLock manager.accessLock:
      manager.lastAccess[topic] = getTime().toUnix() * 1000

  return backend

proc resolveStrategy(manager: StorageManager, topic: string): StorageStrategy {.gcsafe.} =
  ## Resolve storage strategy for a topic
  result = manager.config.resolveStrategy(topic)

proc setTopicStrategy(manager: StorageManager, topic: string,
                      strategy: StorageStrategy) {.gcsafe.} =
  ## Override storage strategy for a specific topic
  ## For hybrid mode - specifies which backend to use
  withLock manager.topicBackendLock:
    manager.topicBackendTypes[topic] = strategy

proc flushPending(manager: StorageManager, topic: string) {.gcsafe.} =
  ## Flush pending messages for a topic
  let backend = manager.getOrCreateBackend(topic)

  if backend of SharedBarrelBackend:
    let sharedBackend = SharedBarrelBackend(backend)
    sharedBackend.flushPending(topic)

proc flushAllPending(manager: StorageManager) {.gcsafe.} =
  ## Flush all pending messages across all backends
  var topics: seq[string]

  withLock manager.backendsLock:
    topics = toSeq(manager.backends.keys)

  for topic in topics:
    manager.flushPending(topic)

proc cleanupIdleBackends(manager: StorageManager) {.gcsafe.} =
  ## Remove backends that haven't been accessed recently
  let now = getTime().toUnix() * 1000
  let timeoutMs = manager.config.backendIdleTimeout * 1000
  var toRemove: seq[string]

  # Find idle backends
  withLock manager.accessLock:
    for topic, lastAccess in manager.lastAccess:
      if now - lastAccess > timeoutMs:
        toRemove.add(topic)

  # Remove idle backends
  for topic in toRemove:
    var backend: HistoryStorageBackend

    withLock manager.backendsLock:
      if topic in manager.backends:
        backend = manager.backends[topic]
        manager.backends.del(topic)

    withLock manager.accessLock:
      manager.lastAccess.del(topic)

    # Close backend if dedicated
    if backend of SharedBarrelBackend:
      let sharedBackend = SharedBarrelBackend(backend)
      # Don't close shared backend - it's singleton
      if sharedBackend != manager.sharedBackend:
        backend.close()
    else:
      backend.close()

proc getMemoryBackend(manager: StorageManager, topic: string): MemoryStorageBackend {.gcsafe.} =
  ## Get memory backend for a topic (for testing/debugging)
  let backend = manager.getOrCreateBackend(topic)

  if backend of MemoryStorageBackend:
    return MemoryStorageBackend(backend)

  return nil

proc getSharedBackend(manager: StorageManager): SharedBarrelBackend {.gcsafe.} =
  ## Get shared barrel backend
  if manager.sharedBackend.isNil:
    manager.initSharedBackend()

  return manager.sharedBackend

proc shutdown(manager: StorageManager) {.gcsafe.} =
  ## Shutdown storage manager and cleanup all backends
  manager.cleanupRunning = false

  # Flush all pending messages
  manager.flushAllPending()

  # Close all cached backends
  var backends: seq[HistoryStorageBackend]

  withLock manager.backendsLock:
    backends = toSeq(manager.backends.values)
    manager.backends.clear()

  withLock manager.accessLock:
    manager.lastAccess.clear()

  # Close backends (but not shared backend - close it separately)
  for backend in backends:
    if backend != manager.sharedBackend:
      backend.close()

  # Close shared backend last
  if not manager.sharedBackend.isNil:
    manager.sharedBackend.close()
    manager.sharedBackend = nil

proc getStats(manager: StorageManager): tuple[
  cachedTopics: int,
  cachedBackends: int,
  pendingBatches: int,
  memoryUsage: tuple[topics: int, messages: int, bytes: int]
] {.gcsafe.} =
  ## Get storage manager statistics
  result.cachedTopics = 0
  result.cachedBackends = 0
  result.pendingBatches = 0
  result.memoryUsage = (0, 0, 0)

  withLock manager.backendsLock:
    result.cachedBackends = manager.backends.len

    # Count topics and memory usage
    for topic, backend in manager.backends:
      if backend of MemoryStorageBackend:
        let memBackend = MemoryStorageBackend(backend)
        let usage = memBackend.getMemoryUsage()
        result.memoryUsage.topics += usage.topics
        result.memoryUsage.messages += usage.messages
        result.memoryUsage.bytes += usage.bytes

      # Topic is counted if it has its own backend entry
      # (not counting topics that use shared backend)
      if backend != manager.sharedBackend and
         not (manager.config.defaultStrategy == ssSharedBarrel and
              manager.config.resolveStrategy(topic) == ssSharedBarrel):
        result.cachedTopics += 1

  withLock manager.batchLock:
    for _, batch in manager.pendingMessages:
      result.pendingBatches += batch.len

## High-level operations that delegate to backends

proc storeMessage(manager: StorageManager, topic: string,
                  message: Message): bool {.gcsafe.} =
  ## Store a message using appropriate backend
  let backend = manager.getOrCreateBackend(topic)
  return backend.store(topic, message)

proc retrieveMessages(manager: StorageManager, topic: string,
                     params: HistoryQueryParams): seq[Message] {.gcsafe.} =
  ## Retrieve messages using appropriate backend
  let backend = manager.getOrCreateBackend(topic)
  return backend.retrieve(topic, params)

proc clearTopicHistory(manager: StorageManager, topic: string): bool {.gcsafe.} =
  ## Clear history for a topic
  let backend = manager.getOrCreateBackend(topic)
  return backend.clear(topic)

proc getTopicCount(manager: StorageManager, topic: string): int {.gcsafe.} =
  ## Get message count for a topic
  let backend = manager.getOrCreateBackend(topic)
  return backend.count(topic)
