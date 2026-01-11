## Pub/Sub Tests for BitBarrel Client
##
## Tests require a BitBarrel server running on localhost:9876
## with pub/sub enabled in configuration
##
## Run: nim c -r tests/test_pubsub.nim

import std/[unittest, net, strformat, times, random, os]
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
      let topic = uniqueTopicName("test/exact")
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
      let topic = uniqueTopicName("test/publish")
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

      let topic = uniqueTopicName("test/receive")
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
      let subId = client.subscribe("user/*")
      sleep(100)

      # Publish matching messages
      discard client.publish("user/login", "user logged in")
      discard client.publish("user/logout", "user logged out")

      # Publish non-matching message
      discard client.publish("system/start", "should not receive")

      # Wait for messages
      let startTime = epochTime()
      while data.received.len < 2 and (epochTime() - startTime) < 3.0:
        client.receiveMessages(100)
        sleep(50)

      check data.received.len >= 2

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

echo "\nNOTE: These tests require a running BitBarrel server on localhost:9876"
echo "with pub/sub enabled. Some tests may fail if server is not available.\n"
