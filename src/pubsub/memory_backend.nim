## Memory Backend - In-Memory History Storage
##
## In-memory ring buffer implementation for pub/sub message history.
## Messages are stored in per-topic sequences with configurable size limits.

import std/[tables, locks, sequtils]
import ./pubsub
import ./storage_backend

const
  defaultMaxMessages* = 100

type
  MemoryStorageBackend* = ref object of HistoryStorageBackend
    ## Per-topic message ring buffers
    messages*: Table[string, seq[Message]]
    messagesLock*: Lock

    ## Per-topic configuration
    maxPerTopic*: int              ## Maximum messages per topic
    topicModes*: Table[string, HistoryMode]
    modesLock*: Lock

proc newMemoryStorageBackend*(maxPerTopic: int = defaultMaxMessages): MemoryStorageBackend =
  ## Create a new memory-only storage backend
  ##
  ## Parameters:
  ##   - maxPerTopic: Maximum messages to retain per topic (ring buffer)
  ##
  ## Returns: New memory backend instance
  result = MemoryStorageBackend(
    name: "memory",
    isPersistent: false,
    messages: initTable[string, seq[Message]](),
    messagesLock: Lock(),
    maxPerTopic: maxPerTopic,
    topicModes: initTable[string, HistoryMode](),
    modesLock: Lock()
  )
  initLock(result.messagesLock)
  initLock(result.modesLock)

method store(backend: MemoryStorageBackend, topic: string,
             message: Message): bool {.gcsafe.} =
  ## Store a message in memory ring buffer
  withLock backend.messagesLock:
    if topic notin backend.messages:
      backend.messages[topic] = @[]

    var messages = backend.messages[topic]
    messages.add(message)

    # Apply ring buffer eviction if over limit
    if messages.len > backend.maxPerTopic:
      backend.messages[topic] = messages[^backend.maxPerTopic..^1]
    else:
      backend.messages[topic] = messages

  return true

method retrieve(backend: MemoryStorageBackend, topic: string,
                params: HistoryQueryParams): seq[Message] {.gcsafe.} =
  ## Retrieve messages from memory ring buffer
  withLock backend.messagesLock:
    if topic notin backend.messages:
      return @[]

    var messages = backend.messages[topic]

    # Filter by sequence if specified
    if params.sinceSeq > 0:
      messages = messages.filterIt(it.sequence >= params.sinceSeq)

    # Limit count if specified
    if params.limit > 0 and messages.len > params.limit:
      # Return most recent messages
      return messages[^params.limit..^1]

    return messages

method clear(backend: MemoryStorageBackend, topic: string): bool {.gcsafe.} =
  ## Clear all messages for a topic
  withLock backend.messagesLock:
    if topic in backend.messages and backend.messages[topic].len > 0:
      backend.messages.del(topic)
      return true

  return false

method count(backend: MemoryStorageBackend, topic: string): int {.gcsafe.} =
  ## Get message count for a topic
  withLock backend.messagesLock:
    if topic in backend.messages:
      return backend.messages[topic].len
  return 0

method close(backend: MemoryStorageBackend) {.gcsafe.} =
  ## Clear all messages (memory cleanup)
  withLock backend.messagesLock:
    backend.messages.clear()

method getMemoryUsage(backend: MemoryStorageBackend): tuple[
  topics: int, messages: int, bytes: int
] {.gcsafe.} =
  ## Get memory usage estimate
  var totalMessages = 0
  var totalBytes = 0

  withLock backend.messagesLock:
    result.topics = backend.messages.len
    for topic, messages in backend.messages:
      totalMessages += messages.len
      for msg in messages:
        # Estimate: topic (avg 20) + payload (avg 100) + overhead (50)
        totalBytes += topic.len + msg.payload.len + 170

  result = (topics: result.topics, messages: totalMessages, bytes: totalBytes)

## Additional operations specific to memory backend

proc setTopicMode*(backend: MemoryStorageBackend, topic: string,
                   mode: HistoryMode) {.gcsafe.} =
  ## Set history mode for a topic (applies to filtering)
  withLock backend.modesLock:
    backend.topicModes[topic] = mode

proc getTopicMode*(backend: MemoryStorageBackend, topic: string): HistoryMode {.gcsafe.} =
  ## Get history mode for a topic
  withLock backend.modesLock:
    if topic in backend.topicModes:
      return backend.topicModes[topic]
  return hmNone

proc clearAll(backend: MemoryStorageBackend): int {.gcsafe.} =
  ## Clear all topics and return count
  withLock backend.messagesLock:
    let count = backend.messages.len
    backend.messages.clear()
    return count

proc getAllTopicCounts(backend: MemoryStorageBackend): seq[tuple[
  topic: string, count: int
]] {.gcsafe.} =
  ## Get message counts for all topics
  result = @[]
  withLock backend.messagesLock:
    for topic, messages in backend.messages:
      result.add((topic: topic, count: messages.len))

## Backward compatibility wrappers matching old HistoryStore API

proc setTopicHistoryMode*(backend: MemoryStorageBackend, topic: string,
                         mode: HistoryMode) {.inline, gcsafe.} =
  backend.setTopicMode(topic, mode)

proc getTopicHistoryMode*(backend: MemoryStorageBackend, topic: string): HistoryMode {.inline, gcsafe.} =
  backend.getTopicMode(topic)

proc addToHistory*(backend: MemoryStorageBackend, topic: string,
                  message: Message): bool {.inline, gcsafe.} =
  backend.store(topic, message)

proc getHistory*(backend: MemoryStorageBackend, topic: string,
                count: int = 0, sinceSeq: uint64 = 0): seq[Message] {.inline, gcsafe.} =
  let params = HistoryQueryParams(
    limit: count,
    sinceSeq: sinceSeq
  )
  backend.retrieve(topic, params)

proc clearHistory*(backend: MemoryStorageBackend, topic: string): bool {.inline, gcsafe.} =
  backend.clear(topic)

proc clearAllHistory*(backend: MemoryStorageBackend): int {.inline, gcsafe.} =
  backend.clearAll()

proc getHistorySize*(backend: MemoryStorageBackend, topic: string): int {.inline, gcsafe.} =
  backend.count(topic)

proc getAllHistorySizes*(backend: MemoryStorageBackend): seq[tuple[
  topic: string, count: int
]] {.inline, gcsafe.} =
  backend.getAllTopicCounts()

proc cleanup*(backend: MemoryStorageBackend) {.inline, gcsafe.} =
  backend.close()

proc getMemoryUsageEstimate*(backend: MemoryStorageBackend): tuple[
  messageCount: int,
  estimatedBytes: int
] {.inline, gcsafe.} =
  let usage = backend.getMemoryUsage()
  (messageCount: usage.messages, estimatedBytes: usage.bytes)
