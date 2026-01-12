## Event Broker - Message routing to PubSubWebSocket clients
##
## The EventBroker receives published messages and routes them to
## connected PubSubWebSocket clients based on their subscriptions.

import std/[tables, strformat, json, locks, times]
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

proc routeEvent*(broker: EventBroker, msg: Message) =
  ## Route a message to all matching subscribers

  let subscribers = broker.pubSubManager.getAllSubscribersForTopic(msg.topic)

  # Convert headers to string
  var headers = ""
  if msg.headers != nil:
    headers = $msg.headers

  # Send to each subscriber
  for sub in subscribers:
    # Check if subscriber wants this message type
    if msg.messageType == mtKvChange and not sub.options.enableKvEvents:
      continue
    if msg.messageType == mtPresence and not sub.options.enablePresence:
      continue

    broker.sendToClient(sub.clientId, msg.topic, msg.messageType,
                        msg.payload, headers)

proc publishKvChange*(broker: EventBroker, barrelName: string,
                      key: string, changeType: KvChangeType,
                      value: string) =
  ## Publish a k/v change event

  let topic = "kv:" & barrelName & ":" & key
  var payload = ""

  if changeType == kvSet:
    payload = value

  let msg = newMessage(topic, mtKvChange, payload)
  broker.routeEvent(msg)

proc publishPresence*(broker: EventBroker, topic: string,
                      eventType: PresenceEventType,
                      clientId: uint64, username: string,
                      metadata: string = "") =
  ## Publish a presence event

  let headers = newJObject()
  headers["eventType"] = %ord(eventType)
  headers["clientId"] = %clientId
  headers["username"] = %username
  if metadata.len > 0:
    try:
      headers["metadata"] = parseJson(metadata)
    except CatchableError:
      discard

  let msg = newMessage(topic, mtPresence, "", headers)
  broker.routeEvent(msg)

proc getClientCount*(broker: EventBroker): int =
  ## Get the number of connected clients

  withLock broker.clientsLock:
    return broker.clients.len

proc cleanup*(broker: EventBroker) =
  ## Clean up resources (call during shutdown)

  withLock broker.clientsLock:
    for _, ws in broker.clients:
      try:
        ws.closeProc(ws.serverPtr)
      except CatchableError:
        discard
    broker.clients.clear()
