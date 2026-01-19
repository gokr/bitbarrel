## Pub/Sub Chat History Example
##
## Demonstrates building a chat room with message history:
## - Subscribing to chat room with history replay
## - Publishing and receiving messages in real-time
## - Retrieving historical messages
## - Pattern subscriptions across multiple rooms
## - Querying subscribers and presence information
##
## Prerequisites:
## - BitBarrel server with pub/sub enabled
## - History storage configured (memory or persistent)
##
## Run:
##   nim c -r examples/pubsub_chat_history.nim

import std/[net, strformat, strutils, times, random, os]
import ../src/bitbarrel_client

proc main() =
  echo "BitBarrel Pub/Sub Chat History Example"
  echo "======================================"
  echo ""

  ## 1. Connect to server
  echo "1. Connecting to BitBarrel server..."
  var client = newClient("localhost", 1337.Port)

  try:
    ## 2. Ensure chat room barrel exists (for persistent storage)
    echo "2. Setting up chat storage..."
    if not client.createBarrel("chat_storage", ""):
      echo "   Using existing chat storage barrel"

    ## 3. Subscribe to a chat room with history replay
    echo ""
    echo "3. Subscribing to 'room:general' with history replay..."
    var options = SubscriptionOptions(
      replayHistory: true,   # Replay recent history on subscribe
      enablePresence: true   # Enable presence notifications
    )
    let subId = client.subscribe("room:general", options)
    echo fmt"   ✓ Subscribed with ID: {subId}"

    ## 4. Set up message handler
    echo ""
    echo "4. Setting up message handler..."
    var messageCount = 0
    client.onMessage = proc(event: PubSubEvent) =
      messageCount.inc
      let timestamp = fromUnix(event.timestamp)
      let timeStr = timestamp.format("HH:mm:ss")

      case event.messageType
      of mtData:
        echo fmt"   💬 [{timeStr}] {event.headers}: {event.payload}"
      of mtPresence:
        echo fmt"   👥 [{timeStr}] Presence: {event.payload}"
      of mtKvChange:
        echo fmt"   📝 [{timeStr}] KV Change: {event.payload}"
      else:
        echo fmt"   📨 [{timeStr}] Unknown: {event.payload}"

    ## 5. Publish some chat messages
    echo ""
    echo "5. Publishing chat messages..."
    let usernames = @["Alice", "Bob", "Charlie", "Dave", "Eve"]

    for i in 0..4:
      let username = usernames[i]
      let messages = @[
        "Hello everyone!",
        "Hi there! How are you?",
        "Doing great! Just testing BitBarrel pub/sub",
        "This is really cool!",
        "History replay works perfectly!"
      ]
      let message = messages[i]
      let headersStr = "{\"user\": \"" & username & "\"}"

      discard client.publish("room:general", mtData, message, headersStr)
      echo fmt"   Sent: {username}: {message}"
      sleep(200)  ## Small delay between messages

    ## Wait for messages to arrive
    sleep(1000)
    echo ""
    echo fmt"   ✓ Received {messageCount} real-time messages"

    ## 6. Retrieve message history
    echo ""
    echo "6. Retrieving message history..."
    try:
      let history = client.getHistory("room:general", limit = 10, sinceSeq = 0)
      echo fmt"   ✓ Found {history.len} historical messages:"
      echo ""
      for msg in history:
        let timestamp = fromUnix(msg.timestamp)
        let timeStr = timestamp.format("MM/dd HH:mm:ss")
        echo fmt"     [{msg.sequence:2d} | {timeStr}] {msg.headers}: {msg.payload}"
    except ClientError as e:
      if "not supported" in e.msg or "not enabled" in e.msg:
        echo "   ⚠ History not enabled on server"
        echo "     Run with history storage to see this feature"
      else:
        raise e

    ## 7. Demonstrate pattern subscription across multiple rooms
    echo ""
    echo "7. Subscribing to ALL rooms with pattern 'room:*'..."
    let patternSubId = client.subscribe("room:*", options)
    echo fmt"   ✓ Pattern subscription ID: {patternSubId}"
    echo "   Now listening to all chat rooms simultaneously"

    ## 8. Publish to different rooms
    echo ""
    echo "8. Publishing to multiple rooms..."
    discard client.publish("room:tech", mtData, "Tech discussion: BitBarrel is awesome!", "{\"user\": \"Dave\"}")
    echo "   → Posted in room:tech"

    discard client.publish("room:random", mtData, "Random chat: Anyone up for coffee?", "{\"user\": \"Eve\"}")
    echo "   → Posted in room:random"

    discard client.publish("room:general", mtData, "General: Hello from all rooms!", "{\"user\": \"Frank\"}")
    echo "   → Posted in room:general"

    sleep(1000)  ## Wait for messages

    ## 9. Query subscribers in the general room
    echo ""
    echo "9. Querying subscribers in 'room:general'..."
    try:
      let subscribers = client.listSubscribers("room:general")
      echo fmt"   ✓ Found {subscribers.len} subscriber(s):"
      for sub in subscribers:
        echo fmt"     - ID: {sub.id} | Pattern: {sub.pattern}"
    except ClientError as e:
      if "not supported" in e.msg:
        echo "   ⚠ Query methods not fully implemented in this client"
      else:
        raise e

    ## 10. Check presence information
    echo ""
    echo "10. Checking presence for 'room:general'..."
    try:
      let presence = client.getPresence("room:general")
      echo fmt"   ✓ Presence info: {presence}"
    except ClientError as e:
      if "not supported" in e.msg:
        echo "   ⚠ Presence not fully implemented"
      else:
        raise e

    ## 11. Demonstrate history filtering with sinceSeq
    echo ""
    echo "11. Demonstrating history filtering (messages since seq #3)..."
    try:
      let recentHistory = client.getHistory("room:general", limit = 100, sinceSeq = 3)
      echo fmt"   ✓ Found {recentHistory.len} messages since sequence #3"
      for msg in recentHistory:
        echo fmt"     - Seq {msg.sequence}: {msg.headers}: {msg.payload}"
    except ClientError as e:
      if "not supported" in e.msg or "not enabled" in e.msg:
        echo "   ⚠ History filtering not available"
      else:
        raise e

    ## 12. Clean up
    echo ""
    echo "12. Cleaning up..."
    discard client.unsubscribe(subId)
    discard client.unsubscribe(patternSubId)
    echo "   ✓ Unsubscribed from all topics"

  except ClientError as e:
    echo ""
    echo "❌ Error: ", e.msg
    if "not enabled" in e.msg or "PubSub" in e.msg:
      echo ""
      echo "💡 Tip: Pub/Sub may not be enabled on your BitBarrel server."
      echo "   Check your server configuration and ensure pubsub is enabled."
    elif "connection" in e.msg or "refused" in e.msg:
      echo ""
      echo "💡 Tip: Make sure BitBarrel server is running on localhost:1337"
      echo "   Start server with: ./bitbarrel --pubsub.enabled=true"
  finally:
    client.close()
    echo ""
    echo "👋 Disconnected from BitBarrel server."

when isMainModule:
  main()
