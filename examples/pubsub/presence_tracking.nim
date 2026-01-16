## BitBarrel Pub/Sub Presence Tracking Example
##
## Demonstrates presence tracking features for real-time applications.
## Shows online/offline notifications, typing indicators, and user status.
##
## Prerequisites:
##   - BitBarrel server running: ./bitbarrel serve
##
## Run with: nim c -r --path:clients/nim/src examples/pubsub/presence_tracking.nim

import std/[os, strformat, json, times]
import ../../clients/nim/src/bitbarrel_client
import ../../src/bitbarrel/barrel

type
  UserStatus = enum
    online, away, busy, offline

  UserInfo = object
    username*: string
    status*: UserStatus
    lastSeen*: int64

proc simulateUser(client: BitBarrelClient, userId: string, username: string) =
  ## Simulate a user connecting and subscribing

  # Generate a unique client ID
  let clientId = userId

  # Subscribe to presence-enabled topic
  let subId = client.subscribe("room:lobby", SubscriptionOptions(
    enablePresence: true
  ))

  echo fmt"  👤 {username} joined (ID: {subId})"

proc main() =
  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "║   BitBarrel Pub/Sub: Presence Tracking Example               ║"
  echo "╚═══════════════════════════════════════════════════════════════╝"
  echo ""

  # Connect multiple clients to simulate a chat room
  echo "→ Setting up chat room with multiple users..."
  echo ""

  var alice = newClient("localhost", 9876.Port)
  var bob = newClient("localhost", 9876.Port)
  var charlie = newClient("localhost", 9876.Port)

  try:
    alice.connect()
    bob.connect()
    charlie.connect()
    echo "✓ All users connected"
    echo ""

    # Enable presence for all users
    echo "→ Enabling presence tracking..."
    echo ""

    alice.onMessage = proc(event: PubSubEvent) =
      if event.messageType == mtPresence:
        let data = parseJson(event.payload)
        let action = data["action"].getStr()
        let username = data["username"].getStr()
        echo fmt"[Alice] 👥 {username} {action}ed the room"

    bob.onMessage = proc(event: PubSubEvent) =
      if event.messageType == mtPresence:
        let data = parseJson(event.payload)
        let action = data["action"].getStr()
        let username = data["username"].getStr()
        echo fmt"[Bob] 👥 {username} {action}ed the room"

    charlie.onMessage = proc(event: PubSubEvent) =
      if event.messageType == mtPresence:
        let data = parseJson(event.payload)
        let action = data["action"].getStr()
        let username = data["username"].getStr()
        echo fmt"[Charlie] 👥 {username} {action}ed the room"

    # Users join the chat room
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Users Joining the Chat Room"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    let aliceSub = alice.subscribe("room:lobby", SubscriptionOptions(
      enablePresence: true
    ))
    simulateUser(alice, "alice-123", "Alice")
    sleep(500)

    let bobSub = bob.subscribe("room:lobby", SubscriptionOptions(
      enablePresence: true
    ))
    simulateUser(bob, "bob-456", "Bob")
    sleep(500)

    let charlieSub = charlie.subscribe("room:lobby", SubscriptionOptions(
      enablePresence: true
    ))
    simulateUser(charlie, "charlie-789", "Charlie")
    sleep(500)

    echo ""

    # Get presence info
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Current Room Presence"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    let presence = alice.getPresence("room:lobby")
    echo fmt"📊 Total members in room: {presence.members.len}"
    echo ""

    for member in presence.members:
      echo fmt"  👤 {member.username:12} (joined: {member.joinedAt})")
      if member.metadata != nil and member.metadata.len > 0:
        echo fmt"      Metadata: {$member.metadata}"
    echo ""

    # Simulate typing indicator
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Typing Indicators"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo "→ Alice starts typing..."
    discard alice.publishData("typing:room:lobby", "user=Alice&status=typing")
    sleep(200)

    echo "→ Bob sees typing indicator"
    echo ""

    # Simulate user going away
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  User Status Changes"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo "→ Charlie goes AFK..."
    discard charlie.publishData("presence:room:lobby", """{"user":"Charlie","status":"away"}""")
    sleep(500)

    echo ""

    # Simulate user leaving
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  User Leaves"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo "→ Bob leaves the room..."
    alice.unsubscribe(bobSub)
    sleep(500)

    echo ""

    # Final presence
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Final Room State"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    let finalPresence = alice.getPresence("room:lobby")
    echo fmt"📊 Final member count: {finalPresence.members.len}"
    echo ""

    for member in finalPresence.members:
      echo fmt"  👤 {member.username:12} (last ping: {member.lastPing})")

    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║   Presence tracking demo complete! 🎉                        ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Use Cases for Presence Tracking:"
    echo ""
    echo "  1. Chat Applications:"
    echo "     • Online/offline indicators"
    echo "     • Typing notifications"
    echo "     • Read receipts"
    echo ""
    echo "  2. Collaborative Tools:"
    echo "     • Who's currently editing"
    echo "     • Cursor positions"
    echo "     • User avatars in document"
    echo ""
    echo "  3. Gaming:"
    echo "     • Player status (ready/playing/away)"
    echo "     • Lobby member list"
    echo "     • Matchmaking state"
    echo ""
    echo "  4. Support Systems:"
    echo "     • Available agents"
    echo "     • Customer wait time"
    echo "     • Queue position"
    echo ""

  except Exception as e:
    echo ""
    echo "❌ Error: {e.msg}"
    echo ""
    quit(1)

  finally:
    echo "→ Cleaning up connections..."
    if alice.connected:
      alice.close()
    if bob.connected:
      bob.close()
    if charlie.connected:
      charlie.close()
    echo "✓ All connections closed"
    echo ""

when isMainModule:
  main()
