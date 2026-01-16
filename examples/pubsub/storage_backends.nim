## BitBarrel Pub/Sub Storage Backends Example
##
## Demonstrates different storage strategies for Pub/Sub message history.
## Shows when to use each backend type and how to configure them.
##
## Prerequisites:
##   - BitBarrel server running: ./bitbarrel serve
##
## Run with: nim c -r --path:clients/nim/src examples/pubsub/storage_backends.nim

import std/[os, strformat, tables]
import ../../src/pubsub/storage_config
import ../../src/pubsub/storage_manager
import ../../src/pubsub/shared_barrel_backend
import ../../src/pubsub/memory_backend
import ../../src/bitbarrel/barrel

proc demonstrateMemoryBackend() =
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Strategy 1: Memory-Only Backend"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Characteristics:"
  echo "  ✓ Fastest performance (no disk I/O)"
  echo "  ✓ Volatile - messages lost on restart"
  echo "  ✓ Per-topic ring buffer"
  echo "  ✓ Best for: Ephemeral chat, live feeds, real-time data"
  echo ""

  var config = initStorageConfig()
  config.defaultStrategy = ssMemoryOnly
  config.defaultTopicConfig.maxMessages = 100  # Keep last 100 messages

  var historyStore = newMemoryHistoryStore(maxMessagesPerTopic=100)

  echo "→ Publishing messages to 'chat:general' (memory backend)..."

  for i in 1..5:
    let seq = historyStore.addToHistory("chat:general", fmt"Message #{i}")
    echo fmt"  ✓ Published message #{seq}"

  echo ""
  echo "→ Retrieving history..."
  let history = historyStore.getHistory("chat:general", limit=10)
  for msg in history:
    echo fmt"  [{msg.sequence}] {msg.data}"

  echo ""
  echo "💡 Note: Messages will be lost if server restarts!"
  echo ""

proc demonstrateSharedBarrelBackend() =
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Strategy 2: Shared Barrel Backend (Persistent)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Characteristics:"
  echo "  ✓ Persistent across restarts"
  echo "  ✓ All topics stored in single barrel file"
  echo "  ✓ Good balance of performance and durability"
  echo "  ✓ Best for: Notifications, audit logs, message history"
  echo ""

  var config = initStorageConfig()
  config.defaultStrategy = ssSharedBarrel
  config.sharedBarrelPath = "data/pubsub_shared.data"
  config.defaultTopicConfig.maxMessages = 1000

  var manager = newStorageManager(config)

  echo "→ Publishing messages to 'notifications:system'..."
  var backend = manager.getBackendForTopic("notifications:system")

  for i in 1..3:
    let seq = backend.addToHistory(fmt"System event #{i}", "type=info")
    echo fmt"  ✓ Published notification #{seq}"

  echo ""
  echo "→ Retrieving history with sequence numbers..."
  let history = backend.getHistory(limit=10)
  for msg in history:
    echo fmt"  [{msg.sequence:04d}] {msg.data}"

  echo ""
  echo "💡 Messages persist across server restarts!"
  echo ""

proc demonstratePerTopicBarrelBackend() =
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Strategy 3: Per-Topic Barrel Backend (Isolated)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Characteristics:"
  echo "  ✓ Each topic has its own barrel file"
  echo "  ✓ Complete isolation between topics"
  echo "  ✓ Better scalability for many topics"
  echo "  ✓ Best for: Multi-tenant apps, isolated messaging"
  echo ""

  var config = initStorageConfig()
  config.defaultStrategy = ssPerTopicBarrel
  config.perTopicConfig.basePath = "data/pubsub_topics/"

  var manager = newStorageManager(config)

  echo "→ Creating backends for different users..."

  # User 1 backend
  var user1Backend = manager.getBackendForTopic("user:alice:notifications")
  for i in 1..2:
    let seq = user1Backend.addToHistory(fmt"Alice notification #{i}", "")
    echo fmt"  ✓ Alice notification #{seq}"

  # User 2 backend
  var user2Backend = manager.getBackendForTopic("user:bob:notifications")
  for i in 1..2:
    let seq = user2Backend.addToHistory(fmt"Bob notification #{i}", "")
    echo fmt"  ✓ Bob notification #{seq}"

  echo ""
  echo "→ Verifying isolation: Alice can't see Bob's messages..."
  let aliceHistory = user1Backend.getHistory(limit=10)
  echo fmt"  Alice has {aliceHistory.len} message(s)"

  let bobHistory = user2Backend.getHistory(limit=10)
  echo fmt"  Bob has {bobHistory.len} message(s)"

  echo ""
  echo "💡 Topics are completely isolated from each other!"
  echo ""

proc demonstrateHybridStrategy() =
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Strategy 4: Hybrid (Pattern-Based Routing)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Characteristics:"
  echo "  ✓ Different strategies for different topic patterns"
  echo "  ✓ Wildcard pattern matching"
  echo "  ✓ Most flexible configuration"
  echo "  ✓ Best for: Complex apps with varied requirements"
  echo ""

  var config = initStorageConfig()

  # Set default strategy
  config.defaultStrategy = ssSharedBarrel
  config.sharedBarrelConfig.barrelPath = "data/pubsub_default.data"

  # High-frequency chat → Memory only (ephemeral)
  var chatConfig = TopicStorageConfig(
    strategy: ssMemoryOnly,
    maxMessages: 50
  )
  config.addTopicOverride("chat:*", chatConfig)
  echo "→ Chat topics (chat:*): Memory-only, 50 messages max"

  # User notifications → Per-topic (isolated)
  var userConfig = TopicStorageConfig(
    strategy: ssPerTopicBarrel,
    maxMessages: 100
  )
  config.addTopicOverride("user:*:notifications", userConfig)
  echo "→ User notifications (user:*:notifications): Per-topic, 100 messages max"

  # System events → Shared with high retention
  var systemConfig = TopicStorageConfig(
    strategy: ssSharedBarrel,
    maxMessages: 1000
  )
  config.addTopicOverride("system:*", systemConfig)
  echo "→ System events (system:*): Shared, 1000 messages max"

  echo ""
  echo "→ Creating topics with different patterns..."

  var manager = newStorageManager(config)

  # Chat topic → Memory
  var chatBackend = manager.getBackendForTopic("chat:general")
  discard chatBackend.addToHistory("Hey everyone!", "user=alice")
  echo "  ✓ chat:general → Memory backend"

  # User topic → Per-topic
  var userBackend = manager.getBackendForTopic("user:alice:notifications")
  discard userBackend.addToHistory("New follower!", "")
  echo "  ✓ user:alice:notifications → Per-topic backend"

  # System topic → Shared
  var systemBackend = manager.getBackendForTopic("system:alerts")
  discard systemBackend.addToHistory("CPU usage high", "severity=warning")
  echo "  ✓ system:alerts → Shared backend"

  echo ""
  echo "→ Pattern matching results:"
  echo fmt"  Pattern 'chat:*' matches: {manager.matchesPattern("chat:general", "chat:*")}"
  echo fmt"  Pattern 'user:*' matches: {manager.matchesPattern("user:alice:notifications", "user:*")}"
  echo ""
  echo "💡 Each topic gets the optimal storage strategy!"
  echo ""

proc main() =
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║   BitBarrel Pub/Sub: Storage Backends Comparison          ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""

  # Demonstrate each backend type
  demonstrateMemoryBackend()
  demonstrateSharedBarrelBackend()
  demonstratePerTopicBarrelBackend()
  demonstrateHybridStrategy()

  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║   Backend demonstrations complete! 🎉                     ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Recommendations:"
  echo ""
  echo "  • Use Memory-Only for: Chat, live feeds, temporary data"
  echo "  • Use Shared Barrel for: Notifications, audit logs"
  echo "  • Use Per-Topic for: Multi-tenant apps, isolation needed"
  echo "  • Use Hybrid for: Complex apps with varied requirements"
  echo ""

when isMainModule:
  main()
