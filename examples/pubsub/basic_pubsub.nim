## BitBarrel Pub/Sub Basic Example
##
## Demonstrates basic Pub/Sub messaging using the network client.
##
## Prerequisites:
##   - BitBarrel server running: ./bitbarrel serve
##
## Run with: nim c -r --path:clients/nim/src examples/pubsub/basic_pubsub.nim

import std/[os, strformat, strutils]
import bitbarrel_client
import bitbarrel

proc main() =
  echo "╔═══════════════════════════════════════════════╗"
  echo "║   BitBarrel Pub/Sub: Basic Usage Example     ║"
  echo "╚═══════════════════════════════════════════════╝"
  echo ""

  # Connect to BitBarrel server
  var client = newClient("localhost", 9876.Port)

  try:
    client.connect()
    echo "✓ Connected to BitBarrel server"
    echo ""

    # Subscribe to a topic
    echo "→ Subscribing to topic 'chat:general'..."
    let subId = client.subscribe("chat:general")
    echo fmt"✓ Subscribed with ID: {subId}"
    echo ""

    # Set up message handler
    client.onMessage = proc(event: PubSubEvent) =
      case event.messageType
      of mtData:
        echo fmt"💬 [Message] {event.topic}: {event.payload}"
      of mtPresence:
        echo fmt"👥 [Presence] {event.topic}: {event.payload}"
      of mtKvChange:
        echo fmt"📝 [KV Change] {event.topic}: {event.payload}"

    # Publish some messages
    echo "→ Publishing messages..."
    echo ""

    let seq1 = client.publishData("chat:general", "Hello, Pub/Sub!")
    echo fmt"✓ Published message #{seq1}"

    let seq2 = client.publishData("chat:general", "This is so easy! 😊")
    echo fmt"✓ Published message #{seq2}"

    let seq3 = client.publishData("chat:general", "Real-time messaging with BitBarrel")
    echo fmt"✓ Published message #{seq3}"
    echo ""

    # Subscribe with pattern matching
    echo "→ Subscribing to pattern 'notifications:*'..."
    let notifSubId = client.subscribe("notifications:*")
    echo fmt"✓ Subscribed to notifications with ID: {notifSubId}"
    echo ""

    # Publish to different notification topics
    let seq4 = client.publishData("notifications:system", "System update completed")
    echo fmt"✓ Published system notification #{seq4}"

    let seq5 = client.publishData("notifications:user:alice", "New message from Bob")
    echo fmt"✓ Published user notification #{seq5}"
    echo ""

    # Demonstrate presence tracking
    echo "→ Getting presence info for 'chat:general'..."
    let presence = client.getPresence("chat:general")
    echo fmt"✓ Found {presence.members.len} member(s) in chat"
    for member in presence.members:
      echo fmt"  - {member.username} (joined: {member.joinedAt})")
    echo ""

    # Wait a bit to see messages (in real app, this would be event-driven)
    echo "→ Waiting for message delivery..."
    sleep(1000)
    echo ""

    echo "╔═══════════════════════════════════════════════╗"
    echo "║   Example completed successfully! 🎉          ║"
    echo "╚═══════════════════════════════════════════════╝"

  except Exception as e:
    echo ""
    echo fmt"❌ Error: {e.msg}"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Make sure BitBarrel server is running: ./bitbarrel serve"
    echo "  2. Check that server is listening on port 9876"
    echo "  3. Verify no firewall is blocking the connection"
    quit(1)

  finally:
    # Clean up
    if client.connected:
      echo "→ Disconnecting..."
      client.close()
      echo "✓ Disconnected"

when isMainModule:
  main()
