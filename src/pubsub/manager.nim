## PubSubManager - Topic and subscription management for BitBarrel
##
## Manages:
## - Topic creation and lifecycle
## - Subscription tracking (exact and pattern-based)
## - Message publishing and routing
## - K/V change event publishing
##
## Thread-safe using locks for all shared state

import std/[tables, locks, sets, times, sequtils, json, options]
import ./pubsub
import ./pattern

type
  ## Callback type for sending messages to WebSocket clients
  MessageCallback* = proc(clientId: uint64, topic: string,
                           messageType: PubSubMessageType,
                           payload: string, headers: string) {.gcsafe.}

  ## K/V change event callback type
  KvChangeCallback* = proc(barrelName: string, key: string,
                           changeType: KvChangeType,
                           value: string) {.gcsafe.}

  ## Pattern subscription for wildcard matching
  PatternSubscription* = ref PatternSubscriptionObj
  PatternSubscriptionObj = object
    id*: string                    ## Subscription ID
    clientId*: uint64              ## WebSocket client ID
    pattern*: string               ## Pattern string
    options*: SubscriptionOptions
    createdAt*: int64

  ## PubSubManager - main pub/sub system component
  PubSubManager* = ref PubSubManagerObj
  PubSubManagerObj {.acyclic.} = object
    ## Topic management
    topics*: Table[string, Topic]        ## Exact topic name -> Topic
    topicsLock*: Lock

    ## Subscription tracking (by client ID)
    clientSubscriptions*: Table[uint64, HashSet[string]]  ## clientId -> subIds
    subscriptions*: Table[string, Subscription]           ## subId -> Subscription
    subsLock*: Lock

    ## Pattern-to-subscribers index for wildcard matching
    patternSubscriptions*: Table[string, HashSet[string]]  ## pattern -> subIds
    patternLock*: Lock

    ## Pattern cache for optimization
    patternCache*: PatternCache

    ## Configuration
    config*: PubSubConfig

    ## Sequence counter for generating subscription IDs
    seqCounter: uint64
    seqLock*: Lock

    ## Callback for sending messages to clients
    messageCallback*: MessageCallback

    ## Callback for k/v change events (forwarded from barrel hooks)
    kvChangeCallback*: KvChangeCallback

    ## K/V change hook registration ID (for cleanup)
    kvHookId*: string

proc newPubSubManager*(config: PubSubConfig = defaultPubSubConfig(),
                       messageCallback: MessageCallback = nil): PubSubManager =
  ## Create a new pub/sub manager

  result = PubSubManager(
    topics: initTable[string, Topic](),
    topicsLock: Lock(),

    clientSubscriptions: initTable[uint64, HashSet[string]](),
    subscriptions: initTable[string, Subscription](),
    subsLock: Lock(),

    patternSubscriptions: initTable[string, HashSet[string]](),
    patternLock: Lock(),

    patternCache: newPatternCache(),

    config: config,

    seqCounter: 0,
    seqLock: Lock(),

    messageCallback: messageCallback,
    kvChangeCallback: nil,
    kvHookId: ""
  )

  initLock(result.topicsLock)
  initLock(result.subsLock)
  initLock(result.patternLock)
  initLock(result.seqLock)

proc generateSubscriptionId*(manager: PubSubManager): string =
  ## Generate a unique subscription ID
  withLock manager.seqLock:
    manager.seqCounter += 1
    result = "sub_" & $manager.seqCounter & "_" & generateUuid()

proc getOrCreateTopic*(manager: PubSubManager, topicName: string): Topic =
  ## Get an existing topic or create a new one
  withLock manager.topicsLock:
    if topicName notin manager.topics:
      if manager.config.maxTopics > 0 and
         manager.topics.len >= manager.config.maxTopics:
        raise newException(ValueError, "Maximum topics reached")

      manager.topics[topicName] = newTopic(topicName, manager.config.defaultTopicConfig)
    result = manager.topics[topicName]

proc subscribe*(manager: PubSubManager, clientId: uint64,
                topic: string, pattern: string = "",
                options: SubscriptionOptions = defaultSubscriptionOptions()): string =
  ## Subscribe a client to a topic or pattern
  ##
  ## Parameters:
  ##   - clientId: WebSocket client ID
  ##   - topic: Exact topic name to subscribe to
  ##   - pattern: Optional pattern for wildcard subscriptions
  ##   - options: Subscription options
  ##
  ## Returns: Subscription ID
  ##
  ## Raises: ValueError if limits exceeded

  let subId = manager.generateSubscriptionId()
  let timestamp = toUnix(getTime())* 1000

  withLock manager.subsLock:
    # Check subscription limit per client
    if manager.config.maxSubscriptionsPerClient > 0:
      if clientId notin manager.clientSubscriptions:
        manager.clientSubscriptions[clientId] = initHashSet[string]()
      if manager.clientSubscriptions[clientId].len >=
         manager.config.maxSubscriptionsPerClient:
        raise newException(ValueError, "Maximum subscriptions per client reached")

    # Check if it's a pattern subscription
    if pattern.len > 0:
      if not validatePattern(pattern):
        raise newException(ValueError, "Invalid pattern: " & pattern)

      # Add to pattern subscriptions
      withLock manager.patternLock:
        if pattern notin manager.patternSubscriptions:
          manager.patternSubscriptions[pattern] = initHashSet[string]()
        manager.patternSubscriptions[pattern].incl(subId)

      # Create pattern subscription record
      manager.subscriptions[subId] = Subscription(
        id: subId,
        clientId: clientId,
        topic: "",
        pattern: pattern,
        createdAt: timestamp,
        lastActive: timestamp,
        options: options
      )
    else:
      # Exact topic subscription
      if not validateTopic(topic):
        raise newException(ValueError, "Invalid topic: " & topic)

      # Get or create topic and add subscriber
      let tpc = manager.getOrCreateTopic(topic)
      if not tpc.addSubscriber(subId):
        raise newException(ValueError, "Maximum subscribers for topic reached")

      # Create subscription record
      manager.subscriptions[subId] = Subscription(
        id: subId,
        clientId: clientId,
        topic: topic,
        pattern: "",
        createdAt: timestamp,
        lastActive: timestamp,
        options: options
      )

    # Track subscription for client
    if clientId notin manager.clientSubscriptions:
      manager.clientSubscriptions[clientId] = initHashSet[string]()
    manager.clientSubscriptions[clientId].incl(subId)

  return subId

proc unsubscribe*(manager: PubSubManager, clientId: uint64,
                  topicOrPattern: string): bool =
  ## Unsubscribe a client from a topic or pattern
  ##
  ## If topicOrPattern is empty, unsubscribes from all subscriptions
  ##
  ## Returns: true if subscription was found and removed

  var subsToRemove: seq[string]

  withLock manager.subsLock:
    if clientId notin manager.clientSubscriptions:
      return false

    let clientSubs = manager.clientSubscriptions[clientId]

    if topicOrPattern.len == 0:
      # Unsubscribe from all subscriptions
      subsToRemove = toSeq(clientSubs)
    else:
      # Find subscriptions matching the topic or pattern
      for subId in clientSubs:
        let sub = manager.subscriptions[subId]
        if sub.topic == topicOrPattern or sub.pattern == topicOrPattern:
          subsToRemove.add(subId)

    # Remove each subscription
    for subId in subsToRemove:
      let sub = manager.subscriptions[subId]

      # Remove from topic
      if sub.topic.len > 0 and sub.topic in manager.topics:
        doAssert manager.topics[sub.topic].removeSubscriber(subId)

      # Remove from pattern subscriptions
      if sub.pattern.len > 0:
        withLock manager.patternLock:
          if sub.pattern in manager.patternSubscriptions:
            manager.patternSubscriptions[sub.pattern].excl(subId)
            if manager.patternSubscriptions[sub.pattern].len == 0:
              manager.patternSubscriptions.del(sub.pattern)

      # Remove from tracking
      manager.clientSubscriptions[clientId].excl(subId)
      manager.subscriptions.del(subId)

  return subsToRemove.len > 0

proc unsubscribeAll*(manager: PubSubManager, clientId: uint64): int =
  ## Unsubscribe a client from all subscriptions
  ##
  ## Returns: Number of subscriptions removed

  var count = 0
  withLock manager.subsLock:
    if clientId in manager.clientSubscriptions:
      count = manager.clientSubscriptions[clientId].len
      for subId in manager.clientSubscriptions[clientId]:
        let sub = manager.subscriptions[subId]

        # Remove from topic
        if sub.topic.len > 0 and sub.topic in manager.topics:
          discard manager.topics[sub.topic].removeSubscriber(subId)

        # Remove from pattern subscriptions
        if sub.pattern.len > 0:
          withLock manager.patternLock:
            if sub.pattern in manager.patternSubscriptions:
              manager.patternSubscriptions[sub.pattern].excl(subId)

      for subId in manager.clientSubscriptions[clientId]:
        manager.subscriptions.del(subId)
      manager.clientSubscriptions.del(clientId)

  return count

proc getSubscribersForTopic*(manager: PubSubManager, topic: string): seq[Subscription] =
  ## Get all exact subscribers for a topic (no patterns)

  result = @[]
  withLock manager.topicsLock:
    if topic notin manager.topics:
      return

    let tpc = manager.topics[topic]
    withLock manager.subsLock:
      for subId in tpc.subscribers:
        if subId in manager.subscriptions:
          result.add(manager.subscriptions[subId])

proc getPatternSubscribersForTopic*(manager: PubSubManager, topic: string): seq[Subscription] =
  ## Get all pattern-matching subscribers for a topic

  result = @[]
  withLock manager.patternLock:
    for pattern, subIds in manager.patternSubscriptions:
      if matchesPattern(topic, pattern):
        withLock manager.subsLock:
          for subId in subIds:
            if subId in manager.subscriptions:
              let sub = manager.subscriptions[subId]
              # Only include if not already in exact topic (deduplicate)
              if sub.pattern == pattern:  # Ensure this is a pattern sub
                result.add(sub)

proc getAllSubscribersForTopic*(manager: PubSubManager, topic: string): seq[Subscription] =
  ## Get all subscribers including exact and pattern-matched

  let exact = manager.getSubscribersForTopic(topic)
  let patterns = manager.getPatternSubscribersForTopic(topic)

  # Combine and deduplicate by subscription ID
  var seen = initHashSet[string]()
  result = @[]

  for sub in exact:
    if sub.id notin seen:
      result.add(sub)
      seen.incl(sub.id)

  for sub in patterns:
    if sub.id notin seen:
      result.add(sub)
      seen.incl(sub.id)

proc publish*(manager: PubSubManager, msg: Message): uint64 =
  ## Publish a message to a topic
  ##
  ## Routes the message to all matching subscribers (exact + pattern)
  ##
  ## Returns: The sequence number for this message
  ##
  ## Note: Updates the message's sequence number

  let tpc = manager.getOrCreateTopic(msg.topic)

  withLock manager.topicsLock:
    tpc.sequence += 1
    msg.sequence = tpc.sequence
    tpc.messageCount += 1

  # Get all subscribers
  let subscribers = manager.getAllSubscribersForTopic(msg.topic)

  # Send to each subscriber
  if manager.messageCallback != nil:
    for sub in subscribers:
      # Check if subscriber wants this message type
      if msg.messageType == mtKvChange and not sub.options.enableKvEvents:
        continue
      if msg.messageType == mtPresence and not sub.options.enablePresence:
        continue

      # Convert headers to JSON string for callback
      var headers = ""
      if msg.headers != nil:
        headers = $msg.headers

      manager.messageCallback(sub.clientId, msg.topic, msg.messageType,
                             msg.payload, headers)

  return msg.sequence

proc publish*(manager: PubSubManager, topic: string,
               messageType: PubSubMessageType = mtData,
               payload: string = "",
               headers: JsonNode = nil): uint64 =
  ## Convenience proc to publish a message
  let msg = newMessage(topic, messageType, payload, headers)
  return manager.publish(msg)

proc publishToKvSubscribers*(manager: PubSubManager, barrelName: string,
                              key: string, changeType: KvChangeType,
                              value: string): uint64 =
  ## Publish a key-value change event to subscribers watching this key
  ##
  ## Topic format: `"kv:#barrelName:#key"`
  ##
  ## Subscribers can match specific keys or patterns like `"kv:#barrelName:*"`

  let topic = "kv:" & barrelName & ":" & key
  var payload = ""

  if changeType == kvSet:
    payload = value
  # For delete, payload remains empty

  return manager.publish(topic, mtKvChange, payload)

proc setKvChangeCallback*(manager: PubSubManager, callback: KvChangeCallback) =
  ## Set the callback for k/v change events
  manager.kvChangeCallback = callback

proc listTopics*(manager: PubSubManager, pattern: string = ""): seq[Topic] =
  ## List topics matching pattern (empty = all)

  result = @[]
  withLock manager.topicsLock:
    for name, tpc in manager.topics:
      if pattern.len == 0 or matchesPattern(name, pattern):
        result.add(tpc)

proc getTopic*(manager: PubSubManager, topic: string): Option[Topic] =
  ## Get topic info (returns none if not found)

  withLock manager.topicsLock:
    if topic in manager.topics:
      return some(manager.topics[topic])
    return none(Topic)

proc listSubscriptions*(manager: PubSubManager, clientId: uint64): seq[Subscription] =
  ## List all subscriptions for a client

  result = @[]
  withLock manager.subsLock:
    if clientId in manager.clientSubscriptions:
      for subId in manager.clientSubscriptions[clientId]:
        if subId in manager.subscriptions:
          result.add(manager.subscriptions[subId])

proc getSubscriptionStats*(manager: PubSubManager): tuple[
  totalTopics: int,
  totalSubscriptions: int,
  totalClients: int,
  totalExactSubs: int,
  totalPatternSubs: int
] =
  ## Get statistics about subscriptions

  var exactSubs = 0
  var patternSubs = 0
  var topicCount = 0
  var subCount = 0
  var clientCount = 0

  withLock manager.subsLock:
    for _, sub in manager.subscriptions:
      if sub.pattern.len > 0:
        inc patternSubs
      else:
        inc exactSubs
    subCount = manager.subscriptions.len
    clientCount = manager.clientSubscriptions.len

  withLock manager.topicsLock:
    topicCount = manager.topics.len

  return (
    totalTopics: topicCount,
    totalSubscriptions: subCount,
    totalClients: clientCount,
    totalExactSubs: exactSubs,
    totalPatternSubs: patternSubs
  )

proc cleanup*(manager: PubSubManager) =
  ## Clean up resources (call during shutdown)

  # Remove all pattern subscriptions
  withLock manager.patternLock:
    manager.patternSubscriptions.clear()

  # Clear pattern cache
  if manager.patternCache != nil:
    manager.patternCache.clearCache()

  # Clear all subscriptions
  withLock manager.subsLock:
    manager.clientSubscriptions.clear()
    manager.subscriptions.clear()

  # Clear all topics
  withLock manager.topicsLock:
    manager.topics.clear()

  # Unregister k/v hook if registered
  if manager.kvHookId.len > 0:
    manager.kvHookId = ""
