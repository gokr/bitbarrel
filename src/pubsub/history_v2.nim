## HistoryStoreV2 - Enhanced History Storage API
##
## Public API for pub/sub message history using pluggable storage backends.
## Maintains backward compatibility while providing extensible architecture.

import std/[tables, locks, times, sequtils]
import ./pubsub
import ./storage_backend
import ./storage_manager
import ./storage_config
import ./memory_backend
import ../bitbarrel/barrel

## Default history limits
const defaultHistoryLimit* = 100
const defaultMaxMessagesPerTopic* = 100

type
  HistoryStoreV2* = ref object
    ## Storage manager for backend operations
    storageManager*: StorageManager

    ## Default configuration applied to new topics
    defaultTopicConfig*: TopicConfig

    ## Track topic metadata
    topicMetadata*: Table[string, TopicMetadata]
    metadataLock*: Lock

  TopicConfig* = object
    ## Per-topic configuration
    maxSubscribers*: int
    historyEnabled*: bool
    historyMode*: HistoryMode
    historyMaxMessages*: int
    historyRetentionHours*: int
    persistenceEnabled*: bool

  TopicMetadata* = object
    ## Runtime metadata for a topic
    sequence*: uint64        ## Next sequence number
    messageCount*: int64     ## Total messages published
    createdAt*: int64        ## Unix timestamp (ms)
    subscriberCount*: int    ## Current subscriber count

proc newHistoryStoreV2*(storageManager: StorageManager): HistoryStoreV2 =
  ## Create a new history store with storage manager
  ##
  ## Parameters:
  ##   - storageManager: Storage manager for backend operations
  result = HistoryStoreV2(
    storageManager: storageManager,
    defaultTopicConfig: TopicConfig(
      maxSubscribers: 0,  # Unlimited
      historyEnabled: true,
      historyMode: hmMemoryOnly,
      historyMaxMessages: defaultMaxMessagesPerTopic,
      historyRetentionHours: 0,  # Forever
      persistenceEnabled: false
    ),
    topicMetadata: initTable[string, TopicMetadata](),
    metadataLock: Lock()
  )

proc newHistoryStoreV2*(config: StorageConfig = initStorageConfig()): HistoryStoreV2 =
  ## Create a new history store with default configuration
  let storageManager = newStorageManager(config)
  result = newHistoryStoreV2(storageManager)

proc setTopicConfig*(store: HistoryStoreV2, topic: string,
                     config: TopicConfig)  =
  ## Set configuration for a topic
  withLock store.metadataLock:
    store.topicMetadata[topic] = TopicMetadata(
      sequence: 0,
      messageCount: 0,
      createdAt: getTime().toUnix() * 1000,
      subscriberCount: 0
    )

    # If persistence enabled, update storage config
    if config.persistenceEnabled:
      var topicStorageConfig = store.storageManager.config.resolveTopicConfig(topic)
      topicStorageConfig.strategy = ssSharedBarrel  # Or based on settings
      store.storageManager.config.addTopicOverride(topic, topicStorageConfig)

proc getTopicConfig*(store: HistoryStoreV2, topic: string): TopicConfig  =
  ## Get configuration for a topic
  withLock store.metadataLock:
    if topic in store.topicMetadata:
      let metadata = store.topicMetadata[topic]
      var config = store.defaultTopicConfig
      config.historyEnabled = metadata.messageCount > 0
      return config

    return store.defaultTopicConfig

proc addToHistory*(store: HistoryStoreV2, topic: string,
                  message: Message)  =
  ## Add message to history
  ##
  ## This is called after successful message publishing
  ## Automatically assigns sequence number and updates topic metadata
  ##
  ## Parameters:
  ##   - topic: Topic name
  ##   - message: Message to store (will be updated with sequence)

  # Get or create topic metadata
  var metadata: TopicMetadata
  withLock store.metadataLock:
    if topic notin store.topicMetadata:
      store.topicMetadata[topic] = TopicMetadata(
        sequence: 0,
        messageCount: 0,
        createdAt: getTime().toUnix() * 1000,
        subscriberCount: 0
      )

    # Update metadata
    metadata = store.topicMetadata[topic]
    metadata.sequence += 1
    metadata.messageCount += 1
    store.topicMetadata[topic] = metadata

  # Assign sequence to message
  message.sequence = metadata.sequence

  # Store using appropriate backend
  let storageConfig = store.storageManager.config.resolveTopicConfig(topic)

  case storageConfig.strategy
  of ssMemoryOnly:
    if store.storageManager.config.defaultStrategy != ssMemoryOnly:
      # Create memory backend for this topic
      let memBackend = newMemoryStorageBackend(storageConfig.maxMessages)
      memBackend.setTopicMode(topic, hmMemoryOnly)
      discard memBackend.store(topic, message)
    else:
      discard store.storageManager.storeMessage(topic, message)

  of ssSharedBarrel, ssHybrid:
    discard store.storageManager.storeMessage(topic, message)

  of ssPerTopicBarrel:
    discard store.storageManager.storeMessage(topic, message)

proc getHistory*(store: HistoryStoreV2, topic: string,
                count: int = 0, sinceSeq: uint64 = 0): seq[Message]  =
  ## Get historical messages for a topic
  ##
  ## Parameters:
  ##   - topic: Topic name
  ##   - count: Max messages to return (0 = all)
  ##   - sinceSeq: Only return messages with sequence >= this
  ##
  ## Returns: Sequence of messages (empty if none found)
  let params = HistoryQueryParams(
    limit: count,
    sinceSeq: sinceSeq
  )
  return store.storageManager.retrieveMessages(topic, params)

proc clearHistory*(store: HistoryStoreV2, topic: string): bool  =
  ## Clear all history for a topic
  ##
  ## Parameters:
  ##   - topic: Topic name to clear
  ##
  ## Returns: true if history was cleared
  result = store.storageManager.clearTopicHistory(topic)

  # Update metadata
  if result:
    withLock store.metadataLock:
      if topic in store.topicMetadata:
        var metadata = store.topicMetadata[topic]
        metadata.messageCount = 0
        store.topicMetadata[topic] = metadata

proc clearAllHistory*(store: HistoryStoreV2): int  =
  ## Clear history for all topics
  ##
  ## Returns: Number of topics cleared
  result = 0

  var topics: seq[string]
  withLock store.metadataLock:
    topics = toSeq(store.topicMetadata.keys)

  for topic in topics:
    if store.clearHistory(topic):
      result += 1

proc getHistorySize*(store: HistoryStoreV2, topic: string): int  =
  ## Get the number of messages stored in history for a topic
  return store.storageManager.getTopicCount(topic)

proc getAllTopicSequences*(store: HistoryStoreV2): seq[tuple[
  topic: string, sequence: uint64
]]  =
  ## Get current sequence numbers for all topics
  result = @[]
  withLock store.metadataLock:
    for topic, metadata in store.topicMetadata:
      result.add((topic: topic, sequence: metadata.sequence))

proc getAllHistorySizes*(store: HistoryStoreV2): seq[tuple[
  topic: string, count: int
]]  =
  ## Get history sizes for all topics with history
  result = @[]
  var topics: seq[string]

  withLock store.metadataLock:
    topics = toSeq(store.topicMetadata.keys)

  for topic in topics:
    let count = store.getHistorySize(topic)
    if count > 0:
      result.add((topic: topic, count: count))

proc getMemoryUsageEstimate*(store: HistoryStoreV2): tuple[
  messageCount: int,
  estimatedBytes: int
]  =
  ## Estimate total memory usage across all backends
  var memoryTopics: seq[MemoryStorageBackend]

  # Collect memory backends
  withLock store.metadataLock:
    for topic in store.topicMetadata.keys:
      let backend = store.storageManager.getMemoryBackend(topic)
      if backend != nil and backend notin memoryTopics:
        memoryTopics.add(backend)

  # Sum usage from all memory backends
  for backend in memoryTopics:
    let usage = backend.getMemoryUsage()
    result.messageCount += usage.messages
    result.estimatedBytes += usage.bytes

proc getTopicSequence(store: HistoryStoreV2, topic: string): uint64  =
  ## Get current sequence number for a topic
  withLock store.metadataLock:
    if topic in store.topicMetadata:
      return store.topicMetadata[topic].sequence
  return 0

proc setTopicSequence(store: HistoryStoreV2, topic: string, sequence: uint64)  =
  ## Set sequence number for a topic (used during recovery)
  withLock store.metadataLock:
    if topic notin store.topicMetadata:
      store.topicMetadata[topic] = TopicMetadata(
        sequence: sequence,
        messageCount: 0,
        createdAt: getTime().toUnix() * 1000,
        subscriberCount: 0
      )
    else:
      var metadata = store.topicMetadata[topic]
      metadata.sequence = sequence
      store.topicMetadata[topic] = metadata

proc cleanup*(store: HistoryStoreV2)  =
  ## Clean up resources (call during shutdown)
  withLock store.metadataLock:
    store.topicMetadata.clear()

  store.storageManager.shutdown()

## Backward compatibility wrappers (match old HistoryStore API)

proc setTopicHistoryMode*(store: HistoryStoreV2, topic: string,
                         mode: HistoryMode) {.inline.} =
  var config = store.getTopicConfig(topic)
  config.historyMode = mode
  store.setTopicConfig(topic, config)

proc getTopicHistoryMode*(store: HistoryStoreV2, topic: string): HistoryMode {.inline.} =
  let config = store.getTopicConfig(topic)
  if config.historyEnabled:
    if config.persistenceEnabled:
      return hmPersistent
    else:
      return hmMemoryOnly
  else:
    return hmNone

## Convenience constructors

proc newSharedBarrelHistoryStore*(barrelPath: string,
                                 config: BarrelConfig = defaultBarrelConfig()): HistoryStoreV2 =
  ## Create history store with shared barrel backend
  var storageConfig = initStorageConfig()
  storageConfig.setSharedBarrelConfig(barrelPath, config)
  result = newHistoryStoreV2(storageConfig)

proc newMemoryHistoryStore*(maxMessagesPerTopic: int = defaultMaxMessagesPerTopic): HistoryStoreV2 =
  ## Create history store with memory-only backend
  var storageConfig = initStorageConfig()
  storageConfig.defaultTopicConfig.maxMessages = maxMessagesPerTopic
  result = newHistoryStoreV2(storageConfig)
