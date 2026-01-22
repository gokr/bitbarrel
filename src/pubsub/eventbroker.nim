## Event Broker - Message routing to PubSubWebSocket clients
##
## The EventBroker receives published messages and routes them to
## connected PubSubWebSocket clients based on their subscriptions.

import std/[tables, json as stdjson, locks, times, sets]
import sunny
import ./pubsub
import ./manager

type
  ## Send callback type - using raw pointer to avoid ORC cycle detection crashes
  WebSocketSendProc* = proc(wsPtr: pointer, data: string, binary: bool) {.gcsafe.}
  WebSocketCloseProc* = proc(wsPtr: pointer) {.gcsafe.}

  ## Event Broker - routes messages to subscribers
  EventBroker* = ref EventBrokerObj
  EventBrokerObj {.acyclic.} = object
    ## Reference to pub/sub manager
    pubSubManager*: PubSubManager

    ## Client IDs that are subscribed (just the IDs, not full WebSockets)
    clients*: HashSet[uint64]

    ## Clients lock
    clientsLock*: Lock

type
  PresenceHeaders* = object
    eventType {.json: "eventType".}: int
    clientId {.json: "clientId".}: uint64
    username {.json: "username".}: string
    metadata {.json: "metadata".}: RawJson

proc newEventBroker*(pubSubManager: PubSubManager): EventBroker =
  ## Create a new event broker

  result = EventBroker(
    pubSubManager: pubSubManager,
    clients: initHashSet[uint64](),
    clientsLock: Lock()
  )
  initLock(result.clientsLock)

proc addClient*(broker: EventBroker, clientId: uint64) =
  ## Add a client to the broker

  withLock broker.clientsLock:
    broker.clients.incl(clientId)

proc removeClient*(broker: EventBroker, clientId: uint64) =
  ## Remove a client from the broker

  withLock broker.clientsLock:
    broker.clients.excl(clientId)

proc encodeEventMessage*(topic: string, messageType: PubSubMessageType,
                        sequence: uint64, timestamp: int64,
                        headers: string, payload: string): string =
  ## Encode a pub/sub event message for PubSubWebSocket transmission
  ##
  ## Format: `[cmd:1][seq:4][topicLen:2][topic:N][msgType:1][seq:8][ts:8][headersLen:4][headers:M][payloadLen:4][payload:P]`
  ## Note: Uses command byte 0xFF for pub/sub events

  result = newStringOfCap(1 + 4 + 2 + topic.len + 1 + 8 + 8 + 4 + headers.len +
                          4 + payload.len)

  # Command byte (0xFF for pub/sub events)
  result.add(char(0xFF))

  # Sequence placeholder (not used for async events, but required by format)
  result.add(char(0))
  result.add(char(0))
  result.add(char(0))
  result.add(char(0))

  # Topic
  result.add(char((topic.len shr 8) and 0xFF))
  result.add(char(topic.len and 0xFF))
  result.add(topic)

  # Message type
  result.add(char(ord(messageType)))

  # Message sequence
  result.add(char((sequence shr 56) and 0xFF))
  result.add(char((sequence shr 48) and 0xFF))
  result.add(char((sequence shr 40) and 0xFF))
  result.add(char((sequence shr 32) and 0xFF))
  result.add(char((sequence shr 24) and 0xFF))
  result.add(char((sequence shr 16) and 0xFF))
  result.add(char((sequence shr 8) and 0xFF))
  result.add(char(sequence and 0xFF))

  # Timestamp
  result.add(char((timestamp shr 56) and 0xFF))
  result.add(char((timestamp shr 48) and 0xFF))
  result.add(char((timestamp shr 40) and 0xFF))
  result.add(char((timestamp shr 32) and 0xFF))
  result.add(char((timestamp shr 24) and 0xFF))
  result.add(char((timestamp shr 16) and 0xFF))
  result.add(char((timestamp shr 8) and 0xFF))
  result.add(char(timestamp and 0xFF))

  # Headers
  result.add(char((headers.len shr 24) and 0xFF))
  result.add(char((headers.len shr 16) and 0xFF))
  result.add(char((headers.len shr 8) and 0xFF))
  result.add(char(headers.len and 0xFF))
  if headers.len > 0:
    result.add(headers)

  # Payload
  result.add(char((payload.len shr 24) and 0xFF))
  result.add(char((payload.len shr 16) and 0xFF))
  result.add(char((payload.len shr 8) and 0xFF))
  result.add(char(payload.len and 0xFF))
  if payload.len > 0:
    result.add(payload)

proc sendToClient*(broker: EventBroker, clientId: uint64,
                  topic: string, messageType: PubSubMessageType,
                  payload: string, headers: string): string =
  ## Encode a message for a specific client (returns encoded message)
  ## The caller (server) is responsible for actually sending it

  withLock broker.clientsLock:
    if clientId notin broker.clients:
      # Client not connected, skip
      return ""

    # Get topic sequence from manager
    let sequence = if topic in broker.pubSubManager.topics:
                     broker.pubSubManager.topics[topic].sequence
                   else:
                     0'u64

    let timestamp = toUnix(getTime()) * 1000

    result = encodeEventMessage(topic, messageType, sequence,
                                timestamp, headers, payload)

proc routeEvent*(broker: EventBroker, msg: Message): seq[tuple[clientId: uint64, data: string]] =
  ## Route a message to all matching subscribers
  ## Returns sequence of (clientId, encodedMessage) tuples for the server to send

  let subscribers = broker.pubSubManager.getAllSubscribersForTopic(msg.topic)

  # Convert headers to string
  var headers = ""
  if msg.headers.string.len > 0 and msg.headers.string != "{}":
    headers = msg.headers.string

  # Collect messages for all subscribers
  result = @[]
  for sub in subscribers:
    # Check if subscriber wants this message type
    if msg.messageType == mtKvChange and not sub.options.enableKvEvents:
      continue
    if msg.messageType == mtPresence and not sub.options.enablePresence:
      continue

    let encoded = broker.sendToClient(sub.clientId, msg.topic, msg.messageType,
                                     msg.payload, headers)
    if encoded.len > 0:
      result.add((clientId: sub.clientId, data: encoded))

proc publishKvChange*(broker: EventBroker, barrelName: string,
                      key: string, changeType: KvChangeType,
                      value: string): seq[tuple[clientId: uint64, data: string]] =
  ## Publish a k/v change event
  ## Returns list of messages to send

  let topic = "kv:" & barrelName & ":" & key
  var payload = ""

  if changeType == kvSet:
    payload = value

  let msg = newMessage(topic, mtKvChange, payload)
  result = broker.routeEvent(msg)

proc publishPresence*(broker: EventBroker, topic: string,
                      eventType: PresenceEventType,
                      clientId: uint64, username: string,
                      metadata: string = ""): seq[tuple[clientId: uint64, data: string]] =
  ## Publish a presence event
  ## Returns list of messages to send

  var metadataJson: RawJson = RawJson("null")
  if metadata.len > 0:
    try:
      let parsed = stdjson.parseJson(metadata)
      metadataJson = RawJson($parsed)
    except CatchableError:
      discard

  let headersObj = PresenceHeaders(
    eventType: ord(eventType),
    clientId: clientId,
    username: username,
    metadata: metadataJson
  )
  let headers = RawJson($toJson(headersObj))
  let msg = newMessage(topic, mtPresence, "", headers)
  result = broker.routeEvent(msg)

proc getClientCount*(broker: EventBroker): int =
  ## Get the number of connected clients

  withLock broker.clientsLock:
    return broker.clients.card

proc cleanup*(broker: EventBroker) =
  ## Clean up resources (call during shutdown)

  withLock broker.clientsLock:
    broker.clients.clear()
