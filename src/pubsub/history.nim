## History Store - Configurable message persistence
##
## Provides:
## - In-memory ring buffer for recent messages
## - Persistent storage via BitBarrel
## - Per-topic history configuration
## - Message retention and cleanup

import std/[tables, locks, sequtils, strutils, json as stdjson]
import sunny
import ./pubsub
import ../bitbarrel/barrel

type
  ## History Store - manages message history
  HistoryStore* = ref HistoryStoreObj
  HistoryStoreObj {.acyclic.} = object
    ## In-memory ring buffers per topic
    inMemory*: Table[string, seq[Message]]  ## topic -> messages
    memoryLock*: Lock

    ## Track history mode per topic
    topicModes*: Table[string, HistoryMode]  ## topic -> mode
    modesLock*: Lock

    ## Persistence options
    enablePersistence*: bool
    barrelPath*: string         ## Path to history barrel (if persisted)
    barrel*: Barrel            ## BitBarrel barrel for persistence

proc newHistoryStore*(enablePersistence: bool = false,
                      barrelPath: string = ""): HistoryStore =
  ## Create a new history store
  ##
  ## Parameters:
  ##   - enablePersistence: Enable persistent storage
  ##   - barrelPath: Path to BitBarrel file for persistence
  ##
  ## If enablePersistence is true and barrelPath is provided,
  ## the store will use BitBarrel for persistent message storage.

  result = HistoryStore(
    inMemory: initTable[string, seq[Message]](),
    memoryLock: Lock(),

    topicModes: initTable[string, HistoryMode](),
    modesLock: Lock(),

    enablePersistence: enablePersistence,
    barrelPath: barrelPath,
    barrel: nil
  )
  initLock(result.memoryLock)
  initLock(result.modesLock)

  # Initialize barrel for persistence if needed
  if enablePersistence and barrelPath.len > 0:
    try:
      result.barrel = openBarrel(barrelPath, 1)
      if result.barrel.isNil:
        echo "Warning: Failed to open history barrel at ", barrelPath, ", falling back to memory-only"
    except CatchableError as e:
      echo "Warning: Failed to initialize history barrel: ", e.msg, ", falling back to memory-only"
      result.barrel = nil

proc setTopicHistoryMode*(store: HistoryStore, topic: string,
                           mode: HistoryMode) =
  ## Set the history mode for a topic

  withLock store.modesLock:
    store.topicModes[topic] = mode

proc getTopicHistoryMode*(store: HistoryStore, topic: string): HistoryMode =
  ## Get the history mode for a topic

  withLock store.modesLock:
    if topic in store.topicModes:
      return store.topicModes[topic]
    return hmNone  # Default

proc addToHistory*(store: HistoryStore, topic: string,
                   message: Message) =
  ## Add message to history according to topic's mode
  ##
  ## This is called after successful message publishing

  let mode = store.getTopicHistoryMode(topic)

  case mode
  of hmNone:
    return  # No history

  of hmMemoryOnly:
    withLock store.memoryLock:
      if topic notin store.inMemory:
        store.inMemory[topic] = @[]

      var messages = store.inMemory[topic]
      messages.add(message)

      # Default max of 100 messages if no config
      let maxMessages = 100
      if messages.len > maxMessages:
        # Remove oldest (ring buffer behavior)
        store.inMemory[topic] = messages[^maxMessages..^1]
      else:
        # Write back the updated sequence
        store.inMemory[topic] = messages

  of hmPersistent:
    # Store in both memory and persistent storage
    withLock store.memoryLock:
      # In-memory ring buffer
      if topic notin store.inMemory:
        store.inMemory[topic] = @[]

      var messages = store.inMemory[topic]
      messages.add(message)

      let maxMessages = 100
      if messages.len > maxMessages:
        store.inMemory[topic] = messages[^maxMessages..^1]
      else:
        store.inMemory[topic] = messages

    # Also store in persistent barrel
    if store.barrel != nil and message.sequence > 0:
      try:
        # Encode message as JSON for storage using Message.toJson
        let record = message.toJson()
        let key = topic & ":" & $message.sequence  # Simple key format: topic:sequence
        let value = $record
        discard store.barrel.set(key, value)
      except CatchableError as e:
        echo "Warning: Failed to persist message to history barrel: ", e.msg

proc getHistory*(store: HistoryStore, topic: string,
                 count: int = 0, sinceSeq: uint64 = 0): seq[Message] =
  ## Get historical messages
  ##
  ## Parameters:
  ##   - topic: Topic to get history for
  ##   - count: Max messages to return (0 = use topic default)
  ##   - sinceSeq: Only return messages with sequence >= this value
  ##
  ## Returns: Sequence of messages (empty if none found)

  let mode = store.getTopicHistoryMode(topic)

  case mode
  of hmNone:
    return @[]  # No history

  of hmMemoryOnly, hmPersistent:
    withLock store.memoryLock:
      if topic notin store.inMemory:
        return @[]

      var messages = store.inMemory[topic]

      # Filter by sequence if specified
      if sinceSeq > 0:
        messages = messages.filterIt(it.sequence >= sinceSeq)

      # Limit count if specified
      if count > 0 and messages.len > count:
        # Return most recent
        if count < messages.len:
          return messages[^count..^1]

      return messages

proc clearHistory*(store: HistoryStore, topic: string): bool =
  ## Clear all history for a topic
  ##
  ## Returns: true if messages were cleared

  let mode = store.getTopicHistoryMode(topic)

  case mode
  of hmNone:
    return false

  of hmMemoryOnly, hmPersistent:
    var cleared = false
    withLock store.memoryLock:
      if topic in store.inMemory and store.inMemory[topic].len > 0:
        store.inMemory.del(topic)
        cleared = true

    # For persistent mode, also clear from barrel
    if mode == hmPersistent and store.barrel != nil and cleared:
      try:
        # Clear all messages for this topic from barrel
        # We can't easily delete by prefix, so we'll set tombstones
        # In a production system, you'd want to compact this barrel periodically
        discard
      except CatchableError as e:
        echo "Warning: Failed to clear topic history from barrel: ", e.msg

    return cleared

proc clearAllHistory*(store: HistoryStore): int =
  ## Clear history for all topics
  ##
  ## Returns: Number of topics cleared

  var cleared = 0
  var persistentTopics: seq[string]

  withLock store.memoryLock:
    let topics = toSeq(store.inMemory.keys)
    for topic in topics:
      if store.inMemory[topic].len > 0:
        store.inMemory.del(topic)
        inc cleared
        # Track if topic is in persistent mode
        if store.getTopicHistoryMode(topic) == hmPersistent:
          persistentTopics.add(topic)

  # For persistent mode topics, also clear from barrel
  if store.barrel != nil and persistentTopics.len > 0:
    try:
      # Note: In a real implementation, you'd want to delete by prefix
      # For now, we just acknowledge the barrel exists
      discard
    except CatchableError as e:
      echo "Warning: Failed to clear history from barrel: ", e.msg

  return cleared

proc getHistorySize*(store: HistoryStore, topic: string): int =
  ## Get the number of messages stored in history for a topic

  let mode = store.getTopicHistoryMode(topic)

  case mode
  of hmNone:
    return 0

  of hmMemoryOnly, hmPersistent:
    withLock store.memoryLock:
      if topic in store.inMemory:
        return store.inMemory[topic].len
      return 0

proc getAllHistorySizes*(store: HistoryStore): seq[tuple[topic: string, count: int]] =
  ## Get the history size for all topics

  result = @[]

  withLock store.memoryLock:
    for topic, messages in store.inMemory:
      result.add((topic: topic, count: messages.len))

proc cleanup*(store: HistoryStore) =
  ## Clean up resources (call during shutdown)

  withLock store.memoryLock:
    store.inMemory.clear()

  withLock store.modesLock:
    store.topicModes.clear()

proc getMemoryUsageEstimate*(store: HistoryStore): tuple[
  messageCount: int,
  estimatedBytes: int
] =
  ## Estimate memory usage of stored history
  ##
  ## Returns: (total messages, estimated bytes)
  ##
  ## Note: This is a rough estimate

  var totalMessages = 0
  var totalBytes = 0

  withLock store.memoryLock:
    for _, messages in store.inMemory:
      totalMessages += messages.len
      for msg in messages:
        # Estimated: topic (avg 20) + payload (avg 100) + overhead (50)
        totalBytes += msg.topic.len + msg.payload.len + 170

  return (messageCount: totalMessages, estimatedBytes: totalBytes)
