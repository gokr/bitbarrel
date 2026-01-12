## BitBarrel Pub/Sub Demo
##
## Demonstrates real-time publish/subscribe messaging capabilities
## including topic subscriptions, pattern matching, presence tracking,
## message history, and key-value change event integration.
##
## Prerequisites:
##   - BitBarrel server running: nimble server
##   - Nim client library built: nimble install in clients/nim directory
##
## Compilation:
##   nim c -r --path:clients/nim/src --path:src demos/pubsub_demo.nim
##
## Usage:
##   ./pubsub_demo

import std/[os, strformat, times, strutils, locks, threads]
import bitbarrel_client

proc main() =
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║         BitBarrel Pub/Sub Messaging Demo                ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""

  # Create client instance
  echo "🔌 Connecting to BitBarrel server..."
  var client = newClient("localhost", 9876.Port)

  try:
    client.connect()
    echo "   ✓ Connected to server at localhost:9876"
  except ClientError as e:
    echo &"   ✗ Connection failed: {e.msg}"
    echo "   Make sure the server is running: nimble server"
    quit(1)

  echo ""
  echo "📡 Pub/Sub Operations"
  echo "════════════════════════════════════════════════════════════"

  # -----------------------------------------------------------------
  # 1. Basic subscription and publishing
  # -----------------------------------------------------------------
  echo ""
  echo "1️⃣  Basic Subscription & Publishing"
  echo "────────────────────────────────────────────────────────────"

  var receivedMessages: seq[string] = @[]
  var messageLock: Lock
  initLock(messageLock)

  # Set up message handler
  client.onMessage = proc(event: PubSubEvent) =
    withLock(messageLock):
      receivedMessages.add(&"Topic: {event.topic}, Payload: {event.payload}")
    echo &"   📨 Received: {event.topic} → {event.payload}"

  # Subscribe to a specific topic
  echo "   Subscribing to 'demo:greetings'..."
  let subId = client.subscribe("demo:greetings")
  echo &"   ✓ Subscribed with ID: {subId}"

  # Publish a message
  echo "   Publishing welcome message..."
  let seqNo = client.publish("demo:greetings", "Hello from Pub/Sub demo!")
  echo &"   ✓ Published message with sequence: {seqNo}"

  # Give some time for message delivery (simple sleep)
  sleep(100)

  # Check if message was received
  withLock(messageLock):
    if receivedMessages.len > 0:
      echo "   ✓ Message received via callback"
    else:
      echo "   ⚠ No messages received (check server or callback)"

  # -----------------------------------------------------------------
  # 2. Pattern matching subscriptions
  # -----------------------------------------------------------------
  echo ""
  echo "2️⃣  Pattern Matching Subscriptions"
  echo "────────────────────────────────────────────────────────────"

  echo "   Subscribing to pattern 'user:*:notifications'..."
  let patternSubId = client.subscribe("user:*:notifications")
  echo &"   ✓ Pattern subscription ID: {patternSubId}"

  # Publish to matching topics
  echo "   Publishing to matching topics..."
  let seq1 = client.publish("user:alice:notifications", "Alice: You have a new message")
  let seq2 = client.publish("user:bob:notifications", "Bob: Your order shipped")
  let seq3 = client.publish("user:charlie:notifications", "Charlie: Meeting reminder")

  echo &"   ✓ Published 3 messages (sequences: {seq1}, {seq2}, {seq3})"

  # Wait for messages
  sleep(200)

  # -----------------------------------------------------------------
  # 3. Unsubscribe
  # -----------------------------------------------------------------
  echo ""
  echo "3️⃣  Unsubscribing"
  echo "────────────────────────────────────────────────────────────"

  echo "   Unsubscribing from first subscription..."
  if client.unsubscribe(subId):
    echo &"   ✓ Unsubscribed from {subId}"
  else:
    echo &"   ⚠ Failed to unsubscribe (maybe already unsubscribed)"

  # Publish again - should not be received (but pattern subscription still active)
  echo "   Publishing to 'demo:greetings' after unsubscribe..."
  discard client.publish("demo:greetings", "This should not be received")
  sleep(100)

  # -----------------------------------------------------------------
  # 4. Presence tracking (if implemented)
  # -----------------------------------------------------------------
  echo ""
  echo "4️⃣  Presence Tracking"
  echo "────────────────────────────────────────────────────────────"

  # Note: getPresence may not be implemented yet
  try:
    echo "   Getting presence for 'demo:greetings'..."
    let presence = client.getPresence("demo:greetings")
    echo &"   ✓ Presence info retrieved"
    echo &"     Members in topic: {presence.members.len}"
    for member in presence.members:
      echo &"     - {member.username} ({member.clientId})"
  except:
    echo "   ⚠ getPresence() not yet implemented (Phase 4 pending)"

  # -----------------------------------------------------------------
  # 5. Message history (if implemented)
  # -----------------------------------------------------------------
  echo ""
  echo "5️⃣  Message History"
  echo "────────────────────────────────────────────────────────────"

  try:
    echo "   Getting message history for 'demo:greetings'..."
    let history = client.getHistory("demo:greetings", limit=5)
    echo &"   ✓ Retrieved {history.len} historical messages"
    for event in history:
      echo &"     [{event.timestamp}] {event.topic}: {event.payload}"
  except:
    echo "   ⚠ getHistory() not yet implemented (Phase 4 pending)"

  # -----------------------------------------------------------------
  # 6. Key-Value change event integration
  # -----------------------------------------------------------------
  echo ""
  echo "6️⃣  Key-Value Change Events"
  echo "────────────────────────────────────────────────────────────"

  # First, create a barrel and subscribe to its KV events
  echo "   Creating barrel 'pubsub_demo'..."
  discard client.createBarrel("pubsub_demo")
  discard client.useBarrel("pubsub_demo")
  echo "   ✓ Barrel created and selected"

  # Subscribe to KV change events for this barrel
  echo "   Subscribing to KV change events: 'kv:pubsub_demo:*'..."
  let kvSubId = client.subscribe("kv:pubsub_demo:*")
  echo &"   ✓ Subscribed to KV events with ID: {kvSubId}"

  # Perform KV operations that should trigger events
  echo "   Setting key 'user:test' to trigger KV event..."
  discard client.set("user:test", "Test value for KV event")
  echo "   ✓ Key set"

  sleep(100)

  # -----------------------------------------------------------------
  # 7. Cleanup
  # -----------------------------------------------------------------
  echo ""
  echo "7️⃣  Cleanup"
  echo "────────────────────────────────────────────────────────────"

  echo "   Unsubscribing from all subscriptions..."
  let unsubCount = client.unsubscribeAll()
  echo &"   ✓ Unsubscribed from {unsubCount} subscriptions"

  echo "   Dropping demo barrel..."
  discard client.dropBarrel("pubsub_demo")
  echo "   ✓ Barrel dropped"

  # Close connection
  client.close()
  echo ""
  echo "🔌 Connection closed"

  # Summary
  echo ""
  echo "✨ Demo Summary"
  echo "════════════════════════════════════════════════════════════"
  echo ""
  withLock(messageLock):
    echo &"Total messages received: {receivedMessages.len}"
    if receivedMessages.len > 0:
      echo "Last few messages:"
      for i in max(0, receivedMessages.len - 3) ..< receivedMessages.len:
        echo &"  {receivedMessages[i]}"

  echo ""
  echo "Demo operations demonstrated:"
  echo "  • subscribe(topic) - Subscribe to exact topic"
  echo "  • subscribe(pattern) - Subscribe with wildcard pattern"
  echo "  • publish(topic, payload) - Publish message"
  echo "  • onMessage callback - Receive messages asynchronously"
  echo "  • unsubscribe(subId) - Remove subscription"
  echo "  • unsubscribeAll() - Remove all subscriptions"
  echo "  • getPresence(topic) - Get subscriber presence (if implemented)"
  echo "  • getHistory(topic) - Get message history (if implemented)"
  echo "  • KV change events - Automatic events from set/delete operations"
  echo ""
  echo "Note: Some features (presence, history, query methods) may be"
  echo "      pending implementation in Phase 3-4 of client development."
  echo "      Refer to PUBSUB_STATUS.md for current implementation status."

  deinitLock(messageLock)

when isMainModule:
  main()