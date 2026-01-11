## BitBarrel Pub/Sub System - Core Types and API
##
## Provides types for pub/sub messaging including:
## - Subscriptions (topic and pattern-based)
## - Messages (data, presence, k/v change events)
## - Topics with configurable metadata
## - Presence tracking
## - Configuration options

import std/[tables, locks, times, sets, json, random]

proc generateUuid*(): string =
  ## Generate a simple UUID v4-like identifier
  ## Format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
  template hex(b: byte): string = $(if b < 10: char('0'.ord + b) else: char('a'.ord + b - 10))

  var u: array[16, byte]
  for i in 0..<16:
    u[i] = byte(rand(255))

  # Version 4 (random UUID) - set bits 6-7 to 01
  u[6] = (u[6] and 0x0F) or 0x40
  # Variant 1 - set bit 7 to 0
  u[8] = (u[8] and 0x3F) or 0x80

  result = $hex(u[0]) & $hex(u[1]) & $hex(u[2]) & $hex(u[3]) & "-" &
            $hex(u[4]) & $hex(u[5]) & "-" &
            hex(u[6]) & $hex(u[7]) & "-" &
            hex(u[8]) & $hex(u[9]) & "-" &
            $hex(u[10]) & $hex(u[11]) & $hex(u[12]) & $hex(u[13]) & $hex(u[14]) & $hex(u[15])

type
  ## Represents a client's subscription to a topic or pattern
  Subscription* = ref SubscriptionObj
  SubscriptionObj = object
    id*: string                       ## Unique subscription ID (UUID)
    clientId*: uint64                 ## WebSocket client ID
    topic*: string                    ## Exact topic (if not a pattern)
    pattern*: string                  ## Pattern (if wildcard subscription)
    createdAt*: int64                 ## Unix timestamp in ms
    lastActive*: int64                ## Last activity timestamp
    options*: SubscriptionOptions

  SubscriptionOptions* = object
    enableKvEvents*: bool             ## Receive k/v change events
    enablePresence*: bool             ## Receive presence events
    replayHistory*: bool              ## Replay history on subscribe

  ## Represents a pub/sub message
  Message* = ref MessageObj
  MessageObj = object
    id*: string                       ## UUID
    topic*: string
    messageType*: PubSubMessageType
    payload*: string
    headers*: JsonNode                ## Optional metadata
    timestamp*: int64                 ## Unix timestamp in ms
    sequence*: uint64                 ## Topic-specific sequence number

  PubSubMessageType* = enum
    mtData = 0                        ## Regular data message
    mtPresence                        ## Presence notification
    mtKvChange                        ## Key-value change event

  ## Represents a pub/sub topic with metadata
  Topic* = ref TopicObj
  TopicObj = object
    name*: string
    sequence*: uint64                 ## Next sequence number
    createdAt*: int64
    messageCount*: int64
    subscribers*: HashSet[string]     ## Subscription IDs
    config*: TopicConfig

  TopicConfig* = object
    maxSubscribers*: int              ## 0 = unlimited
    historyEnabled*: bool             ## Store message history
    historyMode*: HistoryMode         ## How to store history
    historyMaxMessages*: int          ## 0 = unlimited
    historyRetentionHours*: int       ## 0 = forever
    persistenceEnabled*: bool         ## Persist to BitBarrel

  HistoryMode* = enum
    hmNone                            ## No history, only new messages
    hmMemoryOnly                      ## Ring buffer in memory, lost on restart
    hmPersistent                      ## Stored in BitBarrel for recovery

  ## Presence info for a topic
  PresenceInfo* = ref PresenceInfoObj
  PresenceInfoObj = object
    topic*: string
    members*: Table[string, PresenceMember]  ## clientId -> member info
    lastUpdate*: int64

  PresenceMember* = object
    clientId*: uint64
    username*: string                 ## From auth session
    joinedAt*: int64
    lastPing*: int64
    metadata*: JsonNode               ## Client-provided metadata

  ## Heartbeat tracker for health checking
  HeartbeatTracker* = ref HeartbeatTrackerObj
  HeartbeatTrackerObj = object
    clientLastSeen*: Table[uint64, int64]
    timeoutMs*: int                   ## Default: 30000 (30s)
    checkIntervalMs*: int             ## Default: 5000 (5s)

  ## Pub/Sub global configuration
  PubSubConfig* = object
    enabled*: bool
    maxTopics*: int                   ## 0 = unlimited
    maxSubscriptionsPerClient*: int   ## 0 = unlimited
    heartbeatTimeoutMs*: int
    heartbeatCheckIntervalMs*: int
    defaultTopicConfig*: TopicConfig

  KvChangeType* = enum
    kvSet = 0                         ## Key was set
    kvDelete = 0x01                   ## Key was deleted

  PresenceEventType* = enum
    peJoin = 0                        ## Client joined
    peLeave = 0x01                    ## Client left
    peUpdate = 0x02                   ## Client update

## Default configuration values

proc defaultSubscriptionOptions*(): SubscriptionOptions =
  ## Returns default subscription options
  result.enableKvEvents = false
  result.enablePresence = false
  result.replayHistory = false

proc defaultTopicConfig*(): TopicConfig =
  ## Returns default topic configuration
  result.maxSubscribers = 0
  result.historyEnabled = false
  result.historyMode = hmNone
  result.historyMaxMessages = 100
  result.historyRetentionHours = 24
  result.persistenceEnabled = false

proc defaultPubSubConfig*(): PubSubConfig =
  ## Returns default pub/sub configuration
  result.enabled = true
  result.maxTopics = 0
  result.maxSubscriptionsPerClient = 0
  result.heartbeatTimeoutMs = 30000
  result.heartbeatCheckIntervalMs = 5000
  result.defaultTopicConfig = defaultTopicConfig()

proc newMessage*(topic: string, messageType: PubSubMessageType,
                payload: string, headers: JsonNode = nil): Message =
  ## Create a new pub/sub message
  result = Message(
    id: generateUuid(),
    topic: topic,
    messageType: messageType,
    payload: payload,
    headers: if headers != nil: headers else: newJObject(),
    timestamp: int64(epochTime() * 1000),  # Milliseconds since epoch
    sequence: 0
  )

proc newTopic*(name: string, config: TopicConfig = defaultTopicConfig()): Topic =
  ## Create a new topic
  result = Topic(
    name: name,
    sequence: 0,
    createdAt: int64(epochTime() * 1000),
    messageCount: 0,
    subscribers: initHashSet[string](),
    config: config
  )

proc addSubscriber*(topic: Topic, subId: string): bool =
  ## Add a subscriber to a topic
  if topic.config.maxSubscribers > 0 and
     topic.subscribers.len >= topic.config.maxSubscribers:
    return false
  topic.subscribers.incl(subId)
  return true

proc removeSubscriber*(topic: Topic, subId: string): bool =
  ## Remove a subscriber from a topic
  if subId in topic.subscribers:
    topic.subscribers.excl(subId)
    return true
  return false

proc subscriberCount*(topic: Topic): int =
  ## Get the number of subscribers for a topic
  topic.subscribers.len

proc newPresenceInfo*(topic: string): PresenceInfo =
  ## Create new presence info for a topic
  result = PresenceInfo(
    topic: topic,
    members: initTable[string, PresenceMember](),
    lastUpdate: int64(epochTime() * 1000)
  )

proc addMember*(presence: PresenceInfo, clientId: uint64,
                username: string, metadata: JsonNode = nil) =
  ## Add a member to presence
  let idStr = $clientId
  presence.members[idStr] = PresenceMember(
    clientId: clientId,
    username: username,
    joinedAt: int64(epochTime() * 1000),
    lastPing: int64(epochTime() * 1000),
    metadata: if metadata != nil: metadata else: newJObject()
  )
  presence.lastUpdate = int64(epochTime() * 1000)

proc removeMember*(presence: PresenceInfo, clientId: uint64): bool =
  ## Remove a member from presence
  let idStr = $clientId
  if idStr in presence.members:
    presence.members.del(idStr)
    presence.lastUpdate = int64(epochTime() * 1000)
    return true
  return false

proc updatePing*(presence: PresenceInfo, clientId: uint64): bool =
  ## Update the last ping time for a member
  let idStr = $clientId
  if idStr in presence.members:
    presence.members[idStr].lastPing = int64(epochTime() * 1000)
    presence.lastUpdate = int64(epochTime() * 1000)
    return true
  return false

proc memberCount*(presence: PresenceInfo): int =
  ## Get the number of members in presence
  presence.members.len

proc newHeartbeatTracker*(timeoutMs: int = 30000,
                         checkIntervalMs: int = 5000): HeartbeatTracker =
  ## Create a new heartbeat tracker
  result = HeartbeatTracker(
    clientLastSeen: initTable[uint64, int64](),
    timeoutMs: timeoutMs,
    checkIntervalMs: checkIntervalMs
  )

proc updateHeartbeat*(tracker: HeartbeatTracker, clientId: uint64) =
  ## Update the last seen time for a client
  tracker.clientLastSeen[clientId] = int64(epochTime() * 1000)

proc shouldRemoveClient*(tracker: HeartbeatTracker, clientId: uint64): bool =
  ## Check if a client should be removed due to timeout
  if clientId in tracker.clientLastSeen:
    let elapsed = int64(epochTime() * 1000) - tracker.clientLastSeen[clientId]
    return elapsed >= tracker.timeoutMs
  return false

proc removeClient*(tracker: HeartbeatTracker, clientId: uint64): bool =
  ## Remove a client from heartbeat tracking
  if clientId in tracker.clientLastSeen:
    tracker.clientLastSeen.del(clientId)
    return true
  return false

proc removeStaleClients*(tracker: HeartbeatTracker): seq[uint64] =
  ## Remove all stale clients and return their IDs
  var stale: seq[uint64]
  let now = int64(epochTime() * 1000)
  for clientId, lastSeen in tracker.clientLastSeen:
    if now - lastSeen >= tracker.timeoutMs:
      stale.add(clientId)
  for clientId in stale:
    tracker.clientLastSeen.del(clientId)
  return stale

proc toJson*(msg: Message): JsonNode =
  ## Convert a message to JSON
  result = newJObject()
  result["id"] = %msg.id
  result["topic"] = %msg.topic
  result["messageType"] = %ord(msg.messageType)
  result["payload"] = %msg.payload
  if msg.headers != nil:
    result["headers"] = msg.headers
  else:
    result["headers"] = newJObject()
  result["timestamp"] = %msg.timestamp
  result["sequence"] = %msg.sequence

proc fromJson*(js: JsonNode): Message =
  ## Create a message from JSON
  result = Message(
    id: js["id"].getStr(),
    topic: js["topic"].getStr(),
    messageType: PubSubMessageType(js["messageType"].getInt()),
    payload: js["payload"].getStr(),
    headers: js["headers"],
    timestamp: js["timestamp"].getInt(),
    sequence: uint64(js["sequence"].getInt())
  )

proc toJson*(member: PresenceMember): JsonNode =
  ## Convert a presence member to JSON
  result = newJObject()
  result["clientId"] = %member.clientId
  result["username"] = %member.username
  result["joinedAt"] = %member.joinedAt
  result["lastPing"] = %member.lastPing
  if member.metadata != nil:
    result["metadata"] = member.metadata
  else:
    result["metadata"] = newJObject()

proc toJson*(presence: PresenceInfo): JsonNode =
  ## Convert presence info to JSON
  result = newJObject()
  result["topic"] = %presence.topic
  result["lastUpdate"] = %presence.lastUpdate
  let membersArray = newJArray()
  for _, member in presence.members:
    membersArray.add(toJson(member))
  result["members"] = membersArray
  result["memberCount"] = %presence.member_count
