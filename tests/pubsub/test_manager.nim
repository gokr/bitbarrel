## Test PubSubManager Module
##
## Tests for topic/subscription management, message publishing, and routing

import std/[unittest, strutils, options, json]
import ../../src/pubsub/[pubsub, manager, pattern]

suite "PubSubManager":
  test "newPubSubManager creates valid manager":
    let manager = newPubSubManager()

    check manager != nil
    let stats = manager.getSubscriptionStats()
    check stats.totalTopics == 0
    check stats.totalSubscriptions == 0
    check stats.totalClients == 0

  test "subscribe creates topic if not exists":
    let manager = newPubSubManager()

    let subId = manager.subscribe(1'u64, "chat:room1")

    check subId.len > 0
    check manager.getTopic("chat:room1").isSome()

  test "subscribe returns unique IDs":
    let manager = newPubSubManager()

    let id1 = manager.subscribe(1'u64, "topic1")
    let id2 = manager.subscribe(1'u64, "topic2")

    check id1 != id2

  test "subscribe exact topic":
    let manager = newPubSubManager()

    let subId = manager.subscribe(1'u64, "chat:room1")

    check subId.startsWith("sub_")
    let stats = manager.getSubscriptionStats()
    check stats.totalSubscriptions == 1
    check stats.totalExactSubs == 1
    check stats.totalPatternSubs == 0

  test "subscribe pattern":
    let manager = newPubSubManager()

    let subId = manager.subscribe(1'u64, "", "user:*")

    check subId.len > 0
    let stats = manager.getSubscriptionStats()
    check stats.totalSubscriptions == 1
    check stats.totalExactSubs == 0
    check stats.totalPatternSubs == 1

  test "subscribe invalid pattern raises error":
    let manager = newPubSubManager()

    expect ValueError:
      discard manager.subscribe(1'u64, "", "invalid pattern with spaces")

  test "subscribe invalid topic raises error":
    let manager = newPubSubManager()

    expect ValueError:
      discard manager.subscribe(1'u64, "invalid topic with spaces")

  test "getSubscribersForTopic returns exact subscribers":
    let manager = newPubSubManager()

    discard manager.subscribe(1'u64, "chat:room1")
    discard manager.subscribe(2'u64, "chat:room1")
    discard manager.subscribe(3'u64, "chat:room2")

    let subs = manager.getSubscribersForTopic("chat:room1")

    check subs.len == 2
    check subs[0].clientId in [1'u64, 2'u64]
    check subs[1].clientId in [1'u64, 2'u64]

  test "getPatternSubscribersForTopic returns matching subscribers":
    let manager = newPubSubManager()

    discard manager.subscribe(1'u64, "", "user:*")
    discard manager.subscribe(2'u64, "", "chat:*")

    let subs1 = manager.getPatternSubscribersForTopic("user:1000")
    check subs1.len == 1
    check subs1[0].clientId == 1'u64

    let subs2 = manager.getPatternSubscribersForTopic("chat:room1")
    check subs2.len == 1
    check subs2[0].clientId == 2'u64

  test "getAllSubscribersForTopic combines exact and pattern":
    let manager = newPubSubManager()

    discard manager.subscribe(1'u64, "user:1000")
    discard manager.subscribe(2'u64, "", "user:*")

    let subs = manager.getAllSubscribersForTopic("user:1000")

    check subs.len == 2
    check subs[0].clientId in [1'u64, 2'u64]
    check subs[1].clientId in [1'u64, 2'u64]

  test "unsubscribe from exact topic":
    let manager = newPubSubManager()

    discard manager.subscribe(1'u64, "chat:room1")
    check manager.unsubscribe(1'u64, "chat:room1")

    let subs = manager.getSubscribersForTopic("chat:room1")
    check subs.len == 0

  test "unsubscribe from pattern":
    let manager = newPubSubManager()

    discard manager.subscribe(1'u64, "", "user:*")
    check manager.unsubscribe(1'u64, "user:*")

    let subs = manager.getPatternSubscribersForTopic("user:1000")
    check subs.len == 0

  test "unsubscribe non-existent returns false":
    let manager = newPubSubManager()

    check not manager.unsubscribe(999'u64, "non-existent")

  test "unsubscribe from all subscriptions":
    let manager = newPubSubManager()

    discard manager.subscribe(1'u64, "topic1")
    discard manager.subscribe(1'u64, "topic2")
    discard manager.subscribe(1'u64, "", "pattern:*")

    check manager.unsubscribe(1'u64, "")  # Empty = all

    let stats = manager.getSubscriptionStats()
    check stats.totalSubscriptions == 0

  test "unsubscribeAll removes all client subscriptions":
    let manager = newPubSubManager()

    discard manager.subscribe(1'u64, "topic1")
    discard manager.subscribe(1'u64, "topic2")
    discard manager.subscribe(2'u64, "topic3")

    let count = manager.unsubscribeAll(1'u64)

    check count == 2
    let stats = manager.getSubscriptionStats()
    check stats.totalSubscriptions == 1  # Only client 2's subscription remains

  test "publish increments sequence":
    let manager = newPubSubManager()

    let seq1 = manager.publish("topic1", mtData, "msg1")
    let seq2 = manager.publish("topic1", mtData, "msg2")

    check seq2 == seq1 + 1

  test "publish creates topic if not exists":
    let manager = newPubSubManager()

    discard manager.publish("new:topic", mtData, "message")

    check manager.getTopic("new:topic").isSome()

  test "publish increments message count":
    let manager = newPubSubManager()

    discard manager.publish("topic1", mtData, "msg1")
    discard manager.publish("topic1", mtData, "msg2")

    let topic = manager.getTopic("topic1")
    check topic.isSome()
    check topic.get().messageCount == 2

  test "publish with headers":
    let manager = newPubSubManager()

    type TestData = ref object
      headers: string

    let received = TestData()

    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      {.gcsafe.}:
        received.headers = headers

    discard manager.subscribe(1'u64, "topic1")

    let msg = newMessage("topic1", mtData, "payload")
    msg.headers = %*{"sender": "alice"}
    discard manager.publish(msg)

    check received.headers.contains("alice")

  test "publish calls message callback for subscribers":
    let manager = newPubSubManager()

    var callCount = 0
    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      inc callCount

    discard manager.subscribe(1'u64, "topic1")
    discard manager.subscribe(2'u64, "topic1")

    discard manager.publish("topic1", mtData, "message")

    check callCount == 2

  test "publish filters by message type - kvChange":
    let manager = newPubSubManager()

    var callCount = 0
    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      inc callCount

    # Subscribe without enableKvEvents
    var options = defaultSubscriptionOptions()
    options.enableKvEvents = false
    discard manager.subscribe(1'u64, "topic1", "", options)

    discard manager.publish("topic1", mtKvChange, "value")

    check callCount == 0  # Should not receive

  test "publish allows kvChange with enableKvEvents":
    let manager = newPubSubManager()

    var callCount = 0
    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      inc callCount

    # Subscribe with enableKvEvents
    var options = defaultSubscriptionOptions()
    options.enableKvEvents = true
    discard manager.subscribe(1'u64, "topic1", "", options)

    discard manager.publish("topic1", mtKvChange, "value")

    check callCount == 1  # Should receive

  test "publish filters by message type - presence":
    let manager = newPubSubManager()

    var callCount = 0
    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      inc callCount

    # Subscribe without enablePresence
    var options = defaultSubscriptionOptions()
    options.enablePresence = false
    discard manager.subscribe(1'u64, "topic1", "", options)

    discard manager.publish("topic1", mtPresence, "")

    check callCount == 0  # Should not receive

  test "publishToKvSubscribers routes to correct topic":
    let manager = newPubSubManager()

    type TestData = ref object
      topic: string
      payload: string

    let received = TestData(topic: "", payload: "")

    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      {.gcsafe.}:
        received.topic = topic
        received.payload = payload

    var options = defaultSubscriptionOptions()
    options.enableKvEvents = true
    discard manager.subscribe(1'u64, "", "kv:testdb:*", options)

    discard manager.publishToKvSubscribers("testdb", "key1", kvSet, "value1")

    check received.topic == "kv:testdb:key1"
    check received.payload == "value1"

  test "publishToKvSubscribers with delete has empty payload":
    let manager = newPubSubManager()

    type TestData = ref object
      payload: string

    let received = TestData(payload: "not empty")

    manager.messageCallback = proc(clientId: uint64, topic: string,
                                   msgType: PubSubMessageType,
                                   payload: string, headers: string) {.gcsafe.} =
      {.gcsafe.}:
        received.payload = payload

    var options = defaultSubscriptionOptions()
    options.enableKvEvents = true
    discard manager.subscribe(1'u64, "", "kv:testdb:*", options)

    discard manager.publishToKvSubscribers("testdb", "key1", kvDelete, "")

    check received.payload == ""

  test "subscriber limit per client enforced":
    var config = defaultPubSubConfig()
    config.maxSubscriptionsPerClient = 2
    let manager = newPubSubManager(config)

    discard manager.subscribe(1'u64, "topic1")
    discard manager.subscribe(1'u64, "topic2")

    expect ValueError:
      discard manager.subscribe(1'u64, "topic3")

  test "topic limit enforced":
    var config = defaultPubSubConfig()
    config.maxTopics = 2
    let manager = newPubSubManager(config)

    discard manager.subscribe(1'u64, "topic1")
    discard manager.subscribe(1'u64, "topic2")

    expect ValueError:
      discard manager.subscribe(1'u64, "topic3")

  test "listTopics returns all topics":
    let manager = newPubSubManager()

    discard manager.publish("topic1", mtData, "msg")
    discard manager.publish("topic2", mtData, "msg")

    let topics = manager.listTopics()

    check topics.len == 2

  test "listTopics with pattern filter":
    let manager = newPubSubManager()

    discard manager.publish("user:1000", mtData, "msg")
    discard manager.publish("user:2000", mtData, "msg")
    discard manager.publish("chat:room1", mtData, "msg")

    let topics = manager.listTopics("user:*")

    check topics.len == 2

  test "getTopic returns none for non-existent":
    let manager = newPubSubManager()

    let topic = manager.getTopic("non-existent")

    check topic.isNone()

  test "getTopic returns topic info":
    let manager = newPubSubManager()

    discard manager.subscribe(1'u64, "chat:room1")
    discard manager.publish("chat:room1", mtData, "msg")

    let topic = manager.getTopic("chat:room1")

    check topic.isSome()
    check topic.get().name == "chat:room1"
    check topic.get().messageCount == 1

  test "listSubscriptions returns client subscriptions":
    let manager = newPubSubManager()

    discard manager.subscribe(1'u64, "topic1")
    discard manager.subscribe(1'u64, "topic2")
    discard manager.subscribe(2'u64, "topic3")

    let subs = manager.listSubscriptions(1'u64)

    check subs.len == 2

  test "getSubscriptionStats accuracy":
    let manager = newPubSubManager()

    discard manager.subscribe(1'u64, "topic1")
    discard manager.subscribe(1'u64, "", "pattern:*")
    discard manager.subscribe(2'u64, "topic2")

    let stats = manager.getSubscriptionStats()

    check stats.totalTopics == 2  # topic1, topic2
    check stats.totalSubscriptions == 3
    check stats.totalClients == 2
    check stats.totalExactSubs == 2
    check stats.totalPatternSubs == 1

  test "cleanup removes all data":
    let manager = newPubSubManager()

    discard manager.subscribe(1'u64, "topic1")
    discard manager.subscribe(2'u64, "", "pattern:*")
    discard manager.publish("topic1", mtData, "msg")

    manager.cleanup()

    let stats = manager.getSubscriptionStats()
    check stats.totalTopics == 0
    check stats.totalSubscriptions == 0
    check stats.totalClients == 0
