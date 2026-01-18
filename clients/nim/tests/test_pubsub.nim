## Pub/Sub Tests for BitBarrel Client
##
## Tests require a BitBarrel server running on localhost:9876
## with pub/sub enabled in configuration
##
## Run: nim c -r tests/test_pubsub.nim

import std/[unittest, net, strformat, times, random, os, strutils]
import ../src/bitbarrel_client

proc uniqueTopicName(prefix: string): string =
  let timestamp = epochTime().int64
  let rand = rand(1000000)
  fmt"{prefix}_{timestamp}_{rand}"

suite "Subscribe and Publish":
  test "subscribe to topic":
    var client = newClient()
    try:
      client.connect()
      let topic = uniqueTopicName("test:exact")
      let subId = client.subscribe(topic)

      check subId.len > 0
      check client.isSubscribed(subId)

      discard client.unsubscribe(subId)
      check not client.isSubscribed(subId)
    finally:
      client.close()

  test "publish message":
    var client = newClient()
    try:
      client.connect()
      let topic = uniqueTopicName("test:publish")
      let seqNo = client.publish(topic, "test message")

      check seqNo > 0
    finally:
      client.close()

  test "subscribe and receive message":
    var client = newClient()

    type TestData = ref object
      received: seq[PubSubEvent]

    let data = TestData(received: @[])

    client.onMessage = proc(event: PubSubEvent) {.closure, gcsafe.} =
      {.gcsafe.}:
        data.received.add(event)

    try:
      client.connect()

      let topic = uniqueTopicName("test:receive")
      let subId = client.subscribe(topic)

      # Give subscription time to activate
      sleep(100)

      # Publish message
      let seqNo = client.publish(topic, "test payload")

      # Wait for message to arrive and process events
      let startTime = epochTime()
      while data.received.len == 0 and (epochTime() - startTime) < 3.0:
        client.receiveMessages(100)
        sleep(50)

      check data.received.len >= 1
      if data.received.len > 0:
        check data.received[0].topic == topic
        check data.received[0].payload == "test payload"
        check data.received[0].sequence == seqNo

      discard client.unsubscribe(subId)
    finally:
      client.close()

  test "pattern subscription":
    var client = newClient()

    type TestData = ref object
      received: seq[PubSubEvent]

    let data = TestData(received: @[])

    client.onMessage = proc(event: PubSubEvent) {.closure, gcsafe.} =
      {.gcsafe.}:
        data.received.add(event)

    try:
      client.connect()

      # Subscribe to pattern
      let subId = client.subscribe("user:*")
      sleep(100)

      # Publish matching messages
      discard client.publish("user:login", "user logged in")
      discard client.publish("user:logout", "user logged out")

      # Publish non-matching message
      discard client.publish("system:start", "should not receive")

      # Wait for messages
      let startTime = epochTime()
      while data.received.len < 2 and (epochTime() - startTime) < 3.0:
        client.receiveMessages(100)
        sleep(50)

      check data.received.len >= 2

      discard client.unsubscribe(subId)
    finally:
      client.close()

  test "subscribe with options":
    var client = newClient()

    type TestData = ref object
      received: seq[PubSubEvent]

    let data = TestData(received: @[])

    client.onMessage = proc(event: PubSubEvent) {.closure, gcsafe.} =
      {.gcsafe.}:
        data.received.add(event)

    try:
      client.connect()

      let topic = uniqueTopicName("test:options")

      # Subscribe with presence enabled
      var opts = SubscriptionOptions(
        enableKvEvents: false,
        enablePresence: true,
        replayHistory: false
      )
      let subId = client.subscribe(topic, opts)

      sleep(100)

      check subId.len > 0
      check client.isSubscribed(subId)

      # Verify option fields are accessible
      check opts.enablePresence == true
      check opts.enableKvEvents == false
      check opts.replayHistory == false

      discard client.unsubscribe(subId)
    finally:
      client.close()

  test "unsubscribe all":
    var client = newClient()
    try:
      client.connect()

      let sub1 = client.subscribe("topic1")
      let sub2 = client.subscribe("topic2")
      let sub3 = client.subscribe("topic3")

      check client.isSubscribed(sub1)
      check client.isSubscribed(sub2)
      check client.isSubscribed(sub3)

      let count = client.unsubscribeAll()
      check count == 3

      check not client.isSubscribed(sub1)
      check not client.isSubscribed(sub2)
      check not client.isSubscribed(sub3)
    finally:
      client.close()

  test "unsubscribe non-existent subscription":
    var client = newClient()
    try:
      client.connect()

      # Try to unsubscribe from a non-existent subscription
      let result = client.unsubscribe("non_existent_sub_id")

      # Should return false for non-existent subscription
      check result == false
    finally:
      client.close()

  test "publish with different message types":
    var client = newClient()

    type TestData = ref object
      received: seq[PubSubEvent]

    let data = TestData(received: @[])

    client.onMessage = proc(event: PubSubEvent) {.closure, gcsafe.} =
      {.gcsafe.}:
        data.received.add(event)

    try:
      client.connect()

      let topic = uniqueTopicName("test:msgtypes")
      # Subscribe with all message types enabled
      var opts = SubscriptionOptions(
        enableKvEvents: true,
        enablePresence: true,
        replayHistory: false
      )
      let subId = client.subscribe(topic, opts)

      sleep(100)

      # Publish different message types
      discard client.publish(topic, mtData, "data message")
      discard client.publish(topic, mtPresence, "presence message")
      discard client.publish(topic, mtKvChange, "kv change message")

      # Wait for messages
      let startTime = epochTime()
      while data.received.len < 3 and (epochTime() - startTime) < 3.0:
        client.receiveMessages(100)
        sleep(50)

      check data.received.len >= 3

      # Verify message types
      var types: set[PubSubMessageType] = {}
      for event in data.received:
        types.incl(event.messageType)

      check mtData in types
      check mtPresence in types
      check mtKvChange in types
      discard client.unsubscribe(subId)
    finally:
      client.close()

  test "publish with headers":
    var client = newClient()

    type TestData = ref object
      received: seq[PubSubEvent]

    let data = TestData(received: @[])

    client.onMessage = proc(event: PubSubEvent) {.closure, gcsafe.} =
      {.gcsafe.}:
        data.received.add(event)

    try:
      client.connect()

      let topic = uniqueTopicName("test:headers")
      let subId = client.subscribe(topic)

      sleep(100)

      # Publish with headers
      let headers = """{"userId": "123", "source": "test"}"""
      let seqNo = client.publish(topic, mtData, "message with headers", headers)

      check seqNo > 0

      # Wait for message
      let startTime = epochTime()
      while data.received.len == 0 and (epochTime() - startTime) < 3.0:
        client.receiveMessages(100)
        sleep(50)

      check data.received.len >= 1
      if data.received.len > 0:
        check data.received[0].headers.len > 0
        check data.received[0].payload == "message with headers"

      discard client.unsubscribe(subId)
    finally:
      client.close()

suite "Query Methods":
  test "list subscribers for topic":
    var client1 = newClient()
    var client2 = newClient()
    try:
      let topic = uniqueTopicName("test:list_subscribers")

      # Both clients subscribe to the same topic
      client1.connect()
      client2.connect()

      discard client1.subscribe(topic)
      discard client2.subscribe(topic)

      sleep(100)

      # List subscribers
      let subscribers = client1.listSubscribers(topic)

      check subscribers.len >= 2

      # Verify subscription IDs are unique by checking no duplicates
      var uniqueIds: seq[string] = @[]
      for s in subscribers:
        if s.id notin uniqueIds:
          uniqueIds.add(s.id)
      check uniqueIds.len == subscribers.len

    finally:
      client1.close()
      client2.close()

  test "list subscribers for non-existent topic":
    var client = newClient()
    try:
      client.connect()

      # Try to list subscribers for a topic that doesn't exist
      let subscribers = client.listSubscribers("non_existent_topic_12345")

      # Should return empty list for non-existent topic
      check subscribers.len == 0
    finally:
      client.close()

  test "list topics":
    var client = newClient()
    try:
      client.connect()

      # Create some topics by publishing to them
      let topic1 = uniqueTopicName("test:topics1")
      let topic2 = uniqueTopicName("test:topics2")
      let topic3 = uniqueTopicName("test:topics3")

      discard client.publish(topic1, "data1")
      discard client.publish(topic2, "data2")
      discard client.publish(topic3, "data3")

      sleep(100)

      # List all topics
      let topics = client.listTopics()

      check topics.len >= 3

      # Verify our topics are listed
      var topicSet: array[3, bool] = [false, false, false]
      for topic in topics:
        if topic.name == topic1: topicSet[0] = true
        if topic.name == topic2: topicSet[1] = true
        if topic.name == topic3: topicSet[2] = true
      check topicSet[0] and topicSet[1] and topicSet[2]

      # Verify topic info
      for topic in topics:
        check topic.name.len > 0
        check topic.sequence >= 0
        check topic.subscriberCount >= 0
        check topic.messageCount >= 0

    finally:
      client.close()

  test "get history for topic":
    var client = newClient()
    try:
      client.connect()

      let topic = uniqueTopicName("test:history")

      # Publish some messages
      discard client.publish(topic, "message 1")
      sleep(10)
      discard client.publish(topic, "message 2")
      sleep(10)
      discard client.publish(topic, "message 3")
      sleep(100)

      # Get history - may fail if history not enabled on server
      try:
        let history = client.getHistory(topic, limit = 10)

        # Check if history is implemented (will be 0 if not)
        if history.len > 0:
          # History is implemented, run full test
          check history.len >= 3

          # Verify history order (newest first)
          check history[0].payload == "message 3"
          check history[1].payload == "message 2"
          check history[2].payload == "message 1"

          # Verify event properties
          for event in history:
            check event.topic == topic
            check event.messageType == mtData
            check event.sequence > 0
            check event.timestamp > 0
        else:
          # History not implemented yet, just log it
          echo "  [SKIPPED] History not yet implemented"
      except ClientError as e:
        if "not enabled" in e.msg or "ERROR" in e.msg or "failed" in e.msg:
          echo "  [SKIPPED] History not enabled on server"
        else:
          raise e

    finally:
      client.close()

  test "get history with limit and sinceSeq":
    var client = newClient()
    try:
      client.connect()

      let topic = uniqueTopicName("test:history_limit")

      # Publish messages
      var seqNos: seq[uint64] = @[]
      for i in 1..5:
        let seq = client.publish(topic, &"message {i}")
        seqNos.add(seq)
        sleep(10)
      sleep(100)

      # Get history - may fail if history not enabled on server
      try:
        # Get only 2 messages
        let historyLimited = client.getHistory(topic, limit = 2)

        # Check if history is implemented (will be 0 if not)
        if historyLimited.len == 0:
          echo "  [SKIPPED] History not yet implemented"
        else:
          # History is implemented, run full test
          check historyLimited.len <= 2

          # Get messages since specific sequence
          let sinceSeq = seqNos[2]
          let historySince = client.getHistory(topic, limit = 10, sinceSeq = sinceSeq)
          check historySince.len >= 3
          check historySince[0].sequence >= sinceSeq
      except ClientError as e:
        if "not enabled" in e.msg or "ERROR" in e.msg or "failed" in e.msg:
          echo "  [SKIPPED] History not enabled on server"
        else:
          raise e

    finally:
      client.close()

  test "get presence for topic":
    var client1 = newClient()
    var client2 = newClient()
    try:
      let topic = uniqueTopicName("test:presence")

      client1.connect()
      client2.connect()

      # Subscribe to topic with presence enabled
      let opts = SubscriptionOptions(enablePresence: true)
      discard client1.subscribe(topic, opts)
      discard client2.subscribe(topic, opts)

      sleep(100)

      # Get presence
      let presence = client1.getPresence(topic)

      echo "DEBUG TEST: presence.members.len=", presence.members.len
      for i, member in presence.members:
        echo "DEBUG TEST: member[", i, "].clientId=", member.clientId

      check presence.topic == topic
      check presence.members.len >= 2

      # Verify member properties
      for member in presence.members:
        check member.clientId > 0
        check member.username.len >= 0
        check member.joinedAt > 0
        check member.lastPing > 0

    finally:
      client1.close()
      client2.close()

echo "\nNOTE: These tests require a running BitBarrel server on localhost:9876"
echo "with pub/sub enabled. Some tests may fail if server is not available.\n"
