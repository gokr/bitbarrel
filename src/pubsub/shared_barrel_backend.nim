## Shared Barrel Backend - Persistent History Storage
##
## Stores all topic messages in a single BitBarrel barrel with efficient
## prefix-based queries. Uses bmCritBit mode for ordered retrieval.

import std/[tables, locks, sequtils, strutils, json, algorithm]
import sunny
import ./pubsub
import ./storage_backend
import ../bitbarrel/barrel

## Key format for messages in barrel
## msg:{topic}:{padded_sequence}
const MessageKeyPrefix* = "msg:"
const MessageKeySeparator* = ":"

## Metadata key for topic
## meta:{topic}
const MetadataKeyPrefix* = "meta:"

## Sequence number padding width (11 digits = up to 99 billion)
const SequencePadding* = 11

type
  SharedBarrelBackend* = ref object of HistoryStorageBackend
    barrel*: Barrel
    barrelPath*: string
    barrelLock*: Lock

    ## Batch writing support
    pendingMessages*: Table[string, seq[Message]]  ## topic -> batch
    batchLock*: Lock
    batchSize*: int

    ## Counters for unique ID generation
    topicSequences*: Table[string, uint64]
    sequenceLock*: Lock

proc newSharedBarrelBackend*(barrelPath: string, config: BarrelConfig,
                            batchSize: int = 100): SharedBarrelBackend =
  ## Create a new shared barrel backend
  ##
  ## Parameters:
  ##   - barrelPath: Path to barrel file
  ##   - config: Barrel configuration (must use bmCritBit mode!)
  ##   - batchSize: Number of messages to batch before writing
  ##
  ## Raises: ValueError if config.mode is not bmCritBit
  if config.mode != bmCritBit:
    raise newException(ValueError,
      "SharedBarrelBackend requires bmCritBit mode for ordered queries")

  result = SharedBarrelBackend(
    name: "shared_barrel",
    isPersistent: true,
    barrelPath: barrelPath,
    barrelLock: Lock(),
    pendingMessages: initTable[string, seq[Message]](),
    batchLock: Lock(),
    batchSize: batchSize,
    topicSequences: initTable[string, uint64](),
    sequenceLock: Lock()
  )
  initLock(result.barrelLock)
  initLock(result.batchLock)
  initLock(result.sequenceLock)

  # Open barrel
  result.barrel = openBarrel(barrelPath, 1, config)
  if result.barrel.isNil:
    raise newException(ValueError, "Failed to open barrel: " & barrelPath)

# Forward declarations
proc flushPending*(backend: SharedBarrelBackend, topic: string) {.gcsafe.}
proc flushAllPending*(backend: SharedBarrelBackend) {.gcsafe.}

proc formatMessageKey(topic: string, sequence: uint64): string =
  ## Format message key: msg:{topic}:{padded_sequence}
  ## Uses zero-padding for lexicographic ordering
  result = MessageKeyPrefix & topic & MessageKeySeparator & ($sequence).align(SequencePadding, '0')

proc extractSequence(key: string): uint64 =
  ## Extract sequence number from message key
  let parts = key.split(MessageKeySeparator)
  if parts.len >= 3:
    try:
      result = parseUInt(parts[^1])
    except:
      result = 0
  else:
    result = 0

proc formatMetadataKey(topic: string): string =
  ## Format metadata key: meta:{topic}
  result = MetadataKeyPrefix & topic

proc encodeMessage(message: Message): string =
  ## Encode message to JSON for storage
  var data = newJObject()
  data["id"] = %message.id
  data["topic"] = %message.topic
  data["messageType"] = %ord(message.messageType)
  data["payload"] = %message.payload
  data["timestamp"] = %message.timestamp
  data["sequence"] = %message.sequence

  if message.headers.string.len > 0:
    data["headers"] = %message.headers.string

  result = $data

proc decodeMessage(data: string): Message =
  ## Decode message from JSON
  let jsonNode = parseJson(data)

  result = Message()
  result.id = jsonNode["id"].getStr()
  result.topic = jsonNode["topic"].getStr()
  result.messageType = pubsub.PubSubMessageType(jsonNode["messageType"].getInt())
  result.payload = jsonNode["payload"].getStr()
  result.timestamp = jsonNode["timestamp"].getInt()
  result.sequence = uint64(jsonNode["sequence"].getBiggestInt())

  if "headers" in jsonNode:
    result.headers = RawJson($jsonNode["headers"])
  else:
    result.headers = RawJson("{}")

method store(backend: SharedBarrelBackend, topic: string,
             message: Message): bool {.gcsafe.} =
  ## Store a message in the shared barrel
  withLock backend.batchLock:
    # Add to pending batch
    if topic notin backend.pendingMessages:
      backend.pendingMessages[topic] = @[]
    backend.pendingMessages[topic].add(message)

    # Check if batch is full
    if backend.pendingMessages[topic].len >= backend.batchSize:
      let messages = backend.pendingMessages[topic]
      backend.pendingMessages.del(topic)
      return backend.storeBatch(topic, messages)

    return true

method storeBatch(backend: SharedBarrelBackend, topic: string,
                 messages: seq[Message]): bool {.gcsafe.} =
  ## Store multiple messages in batch
  withLock backend.barrelLock:
    # Get current sequence for topic
    var nextSeq: uint64
    withLock backend.sequenceLock:
      if topic notin backend.topicSequences:
        backend.topicSequences[topic] = 0
      nextSeq = backend.topicSequences[topic]

    # Store each message
    for msg in messages:
      nextSeq += 1
      msg.sequence = nextSeq  # Update message with assigned sequence

      let key = formatMessageKey(topic, nextSeq)
      let value = encodeMessage(msg)

      if not backend.barrel.set(key, value):
        return false

    # Update topic sequence counter
    withLock backend.sequenceLock:
      backend.topicSequences[topic] = nextSeq

    # Update topic metadata
    if messages.len > 0:
      let metaKey = formatMetadataKey(topic)
      var metadata = newJObject()
      metadata["lastSequence"] = %nextSeq
      metadata["lastTimestamp"] = %messages[^1].timestamp
      metadata["messageCount"] = %(backend.barrel.countWithPrefix(MessageKeyPrefix & topic & MessageKeySeparator))

      discard backend.barrel.set(metaKey, $metadata)

    return true

method retrieve(backend: SharedBarrelBackend, topic: string,
               params: HistoryQueryParams): seq[Message] {.gcsafe.} =
  ## Retrieve messages from shared barrel
  # Flush any pending messages first
  backend.flushPending(topic)

  let prefix = MessageKeyPrefix & topic & MessageKeySeparator
  var cursor = params.cursor

  # Get messages by prefix
  var allMessages: seq[Message]

  while true:
    let (items, nextCursor, hasMore) = backend.barrel.itemsWithPrefix(prefix, params.limit, cursor)

    # Decode messages
    for (key, value) in items:
      let msg = decodeMessage(value)
      allMessages.add(msg)

    if not hasMore or params.limit == 0:
      break

    cursor = nextCursor

  # Filter by sequence if specified
  if params.sinceSeq > 0:
    allMessages = allMessages.filterIt(it.sequence >= params.sinceSeq)

  if params.beforeSeq > 0:
    allMessages = allMessages.filterIt(it.sequence < params.beforeSeq)

  # Filter by time if specified
  if params.sinceTime > 0:
    allMessages = allMessages.filterIt(it.timestamp >= params.sinceTime)

  # Apply limit
  if params.limit > 0 and allMessages.len > params.limit:
    allMessages = allMessages[^params.limit..^1]

  # Return chronological order (oldest first)
  return allMessages

method clear(backend: SharedBarrelBackend, topic: string): bool {.gcsafe.} =
  ## Clear all messages for a topic
  # Flush pending messages first
  backend.flushPending(topic)

  let prefix = MessageKeyPrefix & topic & MessageKeySeparator

  withLock backend.barrelLock:
    # Get all keys for topic
    let (items, _, _) = backend.barrel.itemsWithPrefix(prefix, 0, "")

    # Delete each message
    for (key, _) in items:
      discard backend.barrel.delete(key)

    # Delete metadata
    let metaKey = formatMetadataKey(topic)
    discard backend.barrel.delete(metaKey)

    # Clear sequence counter
    withLock backend.sequenceLock:
      if topic in backend.topicSequences:
        backend.topicSequences.del(topic)

    return true

method count(backend: SharedBarrelBackend, topic: string): int {.gcsafe.} =
  ## Get message count for a topic
  # Flush pending messages first
  backend.flushPending(topic)

  let prefix = MessageKeyPrefix & topic & MessageKeySeparator
  return backend.barrel.countWithPrefix(prefix)

method close(backend: SharedBarrelBackend) {.gcsafe.} =
  ## Flush all pending messages and close barrel
  backend.flushAllPending()

  withLock backend.barrelLock:
    if backend.barrel != nil:
      backend.barrel.close()
      backend.barrel = nil

proc flushPending*(backend: SharedBarrelBackend, topic: string) {.gcsafe.} =
  ## Flush pending messages for a topic
  withLock backend.batchLock:
    if topic in backend.pendingMessages:
      let messages = backend.pendingMessages[topic]
      backend.pendingMessages.del(topic)

      # Store in background to avoid blocking
      if messages.len > 0:
        discard backend.storeBatch(topic, messages)

proc flushAllPending*(backend: SharedBarrelBackend) {.gcsafe.} =
  ## Flush all pending messages (shutdown)
  var topics: seq[string]

  withLock backend.batchLock:
    topics = toSeq(backend.pendingMessages.keys)

  for topic in topics:
    backend.flushPending(topic)

proc getTopicSequence(backend: SharedBarrelBackend, topic: string): uint64 {.gcsafe.} =
  ## Get current sequence number for a topic
  withLock backend.sequenceLock:
    if topic in backend.topicSequences:
      return backend.topicSequences[topic]
    return 0

proc setTopicSequence(backend: SharedBarrelBackend, topic: string,
                      sequence: uint64) {.gcsafe.} =
  ## Set sequence number for a topic (recovery)
  withLock backend.sequenceLock:
    backend.topicSequences[topic] = sequence

proc loadTopicSequence(backend: SharedBarrelBackend, topic: string) {.gcsafe.} =
  ## Load sequence from barrel metadata
  let metaKey = formatMetadataKey(topic)
  let metadata = backend.barrel.get(metaKey)

  if metadata.len > 0:
    try:
      let jsonNode = parseJson(metadata)
      let lastSeq = uint64(jsonNode["lastSequence"].getBiggestInt())
      backend.setTopicSequence(topic, lastSeq)
    except:
      discard

proc recover(backend: SharedBarrelBackend) {.gcsafe.} =
  ## Recover topic sequences from barrel metadata
  # Scan all metadata keys
  let prefix = MetadataKeyPrefix
  let (items, _, _) = backend.barrel.itemsWithPrefix(prefix, 0, "")

  for (key, _) in items:
    let topic = key[MetadataKeyPrefix.len..^1]
    backend.loadTopicSequence(topic)
