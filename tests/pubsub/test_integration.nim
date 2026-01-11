## Test Pub/Sub Integration
##
## End-to-end integration tests for pub/sub workflows

import std/[unittest, strutils, options, strformat, os, json]
import ../../src/pubsub/pubsub
import ../../src/pubsub/manager
import ../../src/pubsub/barrel_hooks
import ../../src/bitbarrel/barrel
import ../testutils

suite "Pub/Sub Integration":
  setup:
    clearAllHooks()

  teardown:
    clearAllHooks()

  test "barrel set triggers k/v subscriber via hooks":
    # Full integration: Barrel.set → triggerBarrelHooks → PubSubManager → subscribers

    type TestData = ref object
      topic: string
      payload: string
      msgType: pubsub.PubSubMessageType

    let received = TestData(topic: "", payload: "", msgType: pubsub.mtData)

    let manager = newPubSubManager()

    # Set up message callback
    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: pubsub.PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      {.gcsafe.}:
        received.topic = topic
        received.payload = payload
        received.msgType = msgType

    # Subscribe to k/v changes
    var options = defaultSubscriptionOptions()
    options.enableKvEvents = true
    discard manager.subscribe(1'u64, "", "kv:*:*", options)

    # Register hook that forwards to manager
    type ManagerRef = ref object
      m: PubSubManager

    let managerRef = ManagerRef(m: manager)

    proc kvHook(barrel: string, key: string, changeType: pubsub.KvChangeType, value: string) {.gcsafe.} =
      {.gcsafe.}:
        discard managerRef.m.publishToKvSubscribers(barrel, key, changeType, value)

    discard registerBarrelHook(kvHook)

    # Open barrel and set value
    withTestDir("pubsub_kv_integration"):
      let barrel = openBarrel(testDir / "test.data")
      defer: barrel.close()

      discard barrel.set("key1", "value1")

      # Verify hook was called and message delivered
      check received.topic.startsWith("kv:")
      check received.topic.endsWith(":key1")
      check received.payload == "value1"
      check received.msgType == pubsub.mtKvChange

  test "barrel delete triggers k/v subscriber":
    type TestData = ref object
      payload: string

    let received = TestData(payload: "not empty")

    let manager = newPubSubManager()

    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: pubsub.PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      {.gcsafe.}:
        received.payload = payload

    var options = defaultSubscriptionOptions()
    options.enableKvEvents = true
    discard manager.subscribe(1'u64, "", "kv:*:*", options)

    # Register hook that forwards to manager - use ref object to avoid GC-safety issue
    type ManagerRef = ref object
      m: PubSubManager

    let managerRef = ManagerRef(m: manager)

    proc kvHook(barrel: string, key: string, changeType: pubsub.KvChangeType, value: string) {.gcsafe.} =
      {.gcsafe.}:
        discard managerRef.m.publishToKvSubscribers(barrel, key, changeType, value)

    discard registerBarrelHook(kvHook)

    withTestDir("pubsub_delete_integration"):
      let barrel = openBarrel(testDir / "test.data")
      defer: barrel.close()

      discard barrel.set("key1", "value1")
      discard barrel.delete("key1")

      check received.payload == ""  # Delete has empty payload

  test "pattern subscription receives matching messages":
    let manager = newPubSubManager()

    type TestData = ref object
      count: int
      topics: seq[string]

    let received = TestData(count: 0, topics: @[])

    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: pubsub.PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      {.gcsafe.}:
        inc received.count
        received.topics.add(topic)

    # Subscribe to pattern
    discard manager.subscribe(1'u64, "", "user:*")

    # Publish matching messages
    discard manager.publish("user:1000", pubsub.mtData, "message1")
    discard manager.publish("user:2000", pubsub.mtData, "message2")
    discard manager.publish("chat:room1", pubsub.mtData, "message3")  # Won't match

    check received.count == 2
    check "user:1000" in received.topics
    check "user:2000" in received.topics
    check "chat:room1" notin received.topics

  test "subscribe publish receive flow":
    let manager = newPubSubManager()

    type TestData = ref object
      messages: seq[string]

    let received = TestData(messages: @[])

    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: pubsub.PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      {.gcsafe.}:
        received.messages.add(payload)

    # Multiple subscribers
    discard manager.subscribe(1'u64, "chat:room1")
    discard manager.subscribe(2'u64, "chat:room1")

    # Publish message
    discard manager.publish("chat:room1", pubsub.mtData, "Hello everyone!")

    # Both subscribers should receive
    check received.messages.len == 2
    check received.messages[0] == "Hello everyone!"
    check received.messages[1] == "Hello everyone!"

  test "multiple topics independent delivery":
    let manager = newPubSubManager()

    type TestData = ref object
      topic1Messages: seq[string]
      topic2Messages: seq[string]

    let received = TestData(topic1Messages: @[], topic2Messages: @[])

    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: pubsub.PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      {.gcsafe.}:
        if topic == "topic1":
          received.topic1Messages.add(payload)
        elif topic == "topic2":
          received.topic2Messages.add(payload)

    discard manager.subscribe(1'u64, "topic1")
    discard manager.subscribe(2'u64, "topic2")

    discard manager.publish("topic1", pubsub.mtData, "msg1")
    discard manager.publish("topic2", pubsub.mtData, "msg2")

    check received.topic1Messages == @["msg1"]
    check received.topic2Messages == @["msg2"]

  test "unsubscribe stops message delivery":
    let manager = newPubSubManager()

    type TestData = ref object
      count: int

    let received = TestData(count: 0)

    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: pubsub.PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      {.gcsafe.}:
        inc received.count

    discard manager.subscribe(1'u64, "topic1")
    discard manager.publish("topic1", pubsub.mtData, "msg1")
    check received.count == 1

    check manager.unsubscribe(1'u64, "topic1")
    discard manager.publish("topic1", pubsub.mtData, "msg2")
    check received.count == 1  # Should not increment

  test "message type filtering works":
    let manager = newPubSubManager()

    type TestData = ref object
      receivedData: bool
      receivedKv: bool
      receivedPresence: bool

    let received = TestData(receivedData: false, receivedKv: false, receivedPresence: false)

    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: pubsub.PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      {.gcsafe.}:
        case msgType:
        of pubsub.mtData: received.receivedData = true
        of pubsub.mtKvChange: received.receivedKv = true
        of pubsub.mtPresence: received.receivedPresence = true

    # Subscribe with all event types enabled
    var options = defaultSubscriptionOptions()
    options.enableKvEvents = true
    options.enablePresence = true
    discard manager.subscribe(1'u64, "topic1", "", options)

    discard manager.publish("topic1", pubsub.mtData, "data")
    discard manager.publish("topic1", pubsub.mtKvChange, "kv")
    discard manager.publish("topic1", pubsub.mtPresence, "presence")

    check received.receivedData
    check received.receivedKv
    check received.receivedPresence

  test "sequence numbers increment per topic":
    let manager = newPubSubManager()

    let seq1a = manager.publish("topic1", pubsub.mtData, "msg1")
    let seq1b = manager.publish("topic1", pubsub.mtData, "msg2")
    let seq2a = manager.publish("topic2", pubsub.mtData, "msg1")

    check seq1b == seq1a + 1
    check seq2a == 1  # topic2 starts at 1

  test "multiple patterns can match same topic":
    let manager = newPubSubManager()

    type TestData = ref object
      count: int

    let received = TestData(count: 0)

    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: pubsub.PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      {.gcsafe.}:
        inc received.count

    # Two patterns that both match
    discard manager.subscribe(1'u64, "", "user:*")
    discard manager.subscribe(2'u64, "", "*:profile")

    discard manager.publish("user:1000:profile", pubsub.mtData, "msg")

    check received.count == 2  # Both patterns match

  test "exact and pattern subscription both deliver":
    let manager = newPubSubManager()

    type TestData = ref object
      exactReceived: bool
      patternReceived: bool

    let received = TestData(exactReceived: false, patternReceived: false)

    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: pubsub.PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      {.gcsafe.}:
        if clientId == 1:
          received.exactReceived = true
        elif clientId == 2:
          received.patternReceived = true

    discard manager.subscribe(1'u64, "user:1000")
    discard manager.subscribe(2'u64, "", "user:*")

    discard manager.publish("user:1000", pubsub.mtData, "msg")

    check received.exactReceived
    check received.patternReceived

  test "k/v pattern subscription matches all keys":
    type TestData = ref object
      keys: seq[string]

    let received = TestData(keys: @[])

    let manager = newPubSubManager()

    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: pubsub.PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      {.gcsafe.}:
        # Extract key from topic (kv:barrel:key)
        let parts = topic.split(":")
        if parts.len >= 3:
          received.keys.add(parts[2])

    var options = defaultSubscriptionOptions()
    options.enableKvEvents = true
    discard manager.subscribe(1'u64, "", "kv:*:*", options)

    type ManagerRef = ref object
      m: PubSubManager

    let managerRef = ManagerRef(m: manager)

    proc kvHook(barrel: string, key: string, changeType: pubsub.KvChangeType, value: string) {.gcsafe.} =
      {.gcsafe.}:
        discard managerRef.m.publishToKvSubscribers(barrel, key, changeType, value)

    discard registerBarrelHook(kvHook)

    withTestDir("pubsub_multi_key"):
      let barrel = openBarrel(testDir / "test.data")
      defer: barrel.close()

      discard barrel.set("key1", "val1")
      discard barrel.set("key2", "val2")
      discard barrel.set("key3", "val3")

      check received.keys.len == 3
      check "key1" in received.keys
      check "key2" in received.keys
      check "key3" in received.keys

  test "cleanup removes all state":
    let manager = newPubSubManager()

    discard manager.subscribe(1'u64, "topic1")
    discard manager.subscribe(2'u64, "", "pattern:*")
    discard manager.publish("topic1", pubsub.mtData, "msg")

    manager.cleanup()

    let stats = manager.getSubscriptionStats()
    check stats.totalTopics == 0
    check stats.totalSubscriptions == 0
    check stats.totalClients == 0

  test "subscriber limit prevents over-subscription":
    var config = defaultPubSubConfig()
    config.maxSubscriptionsPerClient = 2

    let manager = newPubSubManager(config)

    discard manager.subscribe(1'u64, "topic1")
    discard manager.subscribe(1'u64, "topic2")

    # Third subscription should fail
    expect ValueError:
      discard manager.subscribe(1'u64, "topic3")

    # Other client can still subscribe
    discard manager.subscribe(2'u64, "topic3")

  test "headers pass through correctly":
    let manager = newPubSubManager()

    type TestData = ref object
      headers: string

    let received = TestData(headers: "")

    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: pubsub.PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      {.gcsafe.}:
        received.headers = headers

    discard manager.subscribe(1'u64, "topic1")

    let msg = newMessage("topic1", pubsub.mtData, "payload")
    msg.headers = %*{"sender": "alice", "priority": 1}
    discard manager.publish(msg)

    check received.headers.contains("alice")
    check received.headers.contains("priority")

  test "kv topic format consistency":
    type TestData = ref object
      topic: string

    let received = TestData(topic: "")

    let manager = newPubSubManager()

    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: pubsub.PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      {.gcsafe.}:
        received.topic = topic

    var options = defaultSubscriptionOptions()
    options.enableKvEvents = true
    discard manager.subscribe(1'u64, "", "kv:*", options)

    discard manager.publishToKvSubscribers("mydb", "user:1000", pubsub.kvSet, "Alice")

    check received.topic == "kv:mydb:user:1000"
