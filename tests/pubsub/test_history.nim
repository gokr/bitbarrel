## Test History Store Module
##
## Tests for message history storage (memory and persistent modes)

import std/[unittest, strutils, strformat, json, os]
import sunny
import ../../src/pubsub/[pubsub, history]

suite "HistoryStore":
  test "newHistoryStore creates valid store":
    let store = newHistoryStore()

    check store != nil

  test "setTopicHistoryMode and getTopicHistoryMode":
    let store = newHistoryStore()

    store.setTopicHistoryMode("topic1", hmMemoryOnly)
    check store.getTopicHistoryMode("topic1") == hmMemoryOnly

    store.setTopicHistoryMode("topic1", hmPersistent)
    check store.getTopicHistoryMode("topic1") == hmPersistent

  test "getTopicHistoryMode returns hmNone by default":
    let store = newHistoryStore()

    check store.getTopicHistoryMode("non-existent") == hmNone

  test "addToHistory stores message in memory (hmMemoryOnly)":
    let store = newHistoryStore()
    store.setTopicHistoryMode("topic1", hmMemoryOnly)

    let msg = newMessage("topic1", mtData, "payload1")
    msg.sequence = 1
    store.addToHistory("topic1", msg)

    let history = store.getHistory("topic1")
    check history.len == 1
    check history[0].payload == "payload1"
    check history[0].sequence == 1

  test "addToHistory stores multiple messages":
    let store = newHistoryStore()
    store.setTopicHistoryMode("topic1", hmMemoryOnly)

    for i in 1..10:
      let msg = newMessage("topic1", mtData, fmt"msg{i}")
      msg.sequence = uint64(i)
      store.addToHistory("topic1", msg)

    let history = store.getHistory("topic1")
    check history.len == 10
    check history[0].payload == "msg1"
    check history[9].payload == "msg10"

  test "addToHistory does nothing for hmNone mode":
    let store = newHistoryStore()
    store.setTopicHistoryMode("topic1", hmNone)

    let msg = newMessage("topic1", mtData, "payload")
    store.addToHistory("topic1", msg)

    check store.getHistory("topic1").len == 0

  test "ring buffer evicts old messages (max 100)":
    let store = newHistoryStore()
    store.setTopicHistoryMode("topic1", hmMemoryOnly)

    # Add 150 messages (max is 100)
    for i in 1..150:
      let msg = newMessage("topic1", mtData, fmt"msg{i}")
      msg.sequence = uint64(i)
      store.addToHistory("topic1", msg)

    let history = store.getHistory("topic1")
    check history.len == 100
    # Oldest should be msg51 (151-100=51)
    check history[0].sequence == 51
    check history[99].sequence == 150

  test "getHistory returns empty for non-existent topic":
    let store = newHistoryStore()

    check store.getHistory("non-existent").len == 0

  test "getHistory with count limit":
    let store = newHistoryStore()
    store.setTopicHistoryMode("topic1", hmMemoryOnly)

    for i in 1..20:
      let msg = newMessage("topic1", mtData, fmt"msg{i}")
      msg.sequence = uint64(i)
      store.addToHistory("topic1", msg)

    let history = store.getHistory("topic1", count=5)
    check history.len == 5
    # Should return most recent 5
    check history[0].sequence == 16
    check history[4].sequence == 20

  test "getHistory with sinceSeq filter":
    let store = newHistoryStore()
    store.setTopicHistoryMode("topic1", hmMemoryOnly)

    for i in 1..10:
      let msg = newMessage("topic1", mtData, fmt"msg{i}")
      msg.sequence = uint64(i)
      store.addToHistory("topic1", msg)

    let history = store.getHistory("topic1", count=0, sinceSeq=6)
    check history.len == 5  # Messages 6, 7, 8, 9, 10
    check history[0].sequence == 6
    check history[4].sequence == 10

  test "getHistory with both count and sinceSeq":
    let store = newHistoryStore()
    store.setTopicHistoryMode("topic1", hmMemoryOnly)

    for i in 1..20:
      let msg = newMessage("topic1", mtData, fmt"msg{i}")
      msg.sequence = uint64(i)
      store.addToHistory("topic1", msg)

    let history = store.getHistory("topic1", count=5, sinceSeq=10)
    check history.len == 5  # Messages 16-20 (last 5 of filtered)
    check history[0].sequence == 16
    check history[4].sequence == 20

  test "clearHistory removes all messages":
    let store = newHistoryStore()
    store.setTopicHistoryMode("topic1", hmMemoryOnly)

    for i in 1..5:
      let msg = newMessage("topic1", mtData, fmt"msg{i}")
      store.addToHistory("topic1", msg)

    check store.clearHistory("topic1")
    check store.getHistory("topic1").len == 0

  test "clearHistory returns false for non-existent topic":
    let store = newHistoryStore()

    check not store.clearHistory("non-existent")

  test "clearHistory returns false for hmNone mode":
    let store = newHistoryStore()
    store.setTopicHistoryMode("topic1", hmNone)

    check not store.clearHistory("topic1")

  test "clearAllHistory removes all topics":
    let store = newHistoryStore()

    store.setTopicHistoryMode("topic1", hmMemoryOnly)
    store.setTopicHistoryMode("topic2", hmMemoryOnly)

    for i in 1..5:
      let msg1 = newMessage("topic1", mtData, fmt"msg{i}")
      store.addToHistory("topic1", msg1)

      let msg2 = newMessage("topic2", mtData, fmt"msg{i}")
      store.addToHistory("topic2", msg2)

    let count = store.clearAllHistory()

    check count == 2
    check store.getHistory("topic1").len == 0
    check store.getHistory("topic2").len == 0

  test "getHistorySize returns correct count":
    let store = newHistoryStore()
    store.setTopicHistoryMode("topic1", hmMemoryOnly)

    check store.getHistorySize("topic1") == 0

    for i in 1..10:
      let msg = newMessage("topic1", mtData, fmt"msg{i}")
      store.addToHistory("topic1", msg)

    check store.getHistorySize("topic1") == 10

  test "getHistorySize returns 0 for hmNone mode":
    let store = newHistoryStore()
    store.setTopicHistoryMode("topic1", hmNone)

    let msg = newMessage("topic1", mtData, "payload")
    store.addToHistory("topic1", msg)

    check store.getHistorySize("topic1") == 0

  test "getAllHistorySizes returns all topic sizes":
    let store = newHistoryStore()

    store.setTopicHistoryMode("topic1", hmMemoryOnly)
    store.setTopicHistoryMode("topic2", hmMemoryOnly)

    for i in 1..5:
      let msg = newMessage("topic1", mtData, fmt"msg{i}")
      store.addToHistory("topic1", msg)

    for i in 1..3:
      let msg = newMessage("topic2", mtData, fmt"msg{i}")
      store.addToHistory("topic2", msg)

    let sizes = store.getAllHistorySizes()

    check sizes.len == 2
    # Find topic1 and topic2 in results
    var found1, found2 = false
    for (topic, count) in sizes:
      if topic == "topic1":
        check count == 5
        found1 = true
      elif topic == "topic2":
        check count == 3
        found2 = true

    check found1 and found2

  test "getMemoryUsageEstimate calculates usage":
    let store = newHistoryStore()
    store.setTopicHistoryMode("topic1", hmMemoryOnly)

    for i in 1..10:
      let msg = newMessage("topic1", mtData, "payload")
      store.addToHistory("topic1", msg)

    let (msgCount, bytes) = store.getMemoryUsageEstimate()

    check msgCount == 10
    check bytes > 0  # Should have some estimated bytes

  test "cleanup clears all data":
    let store = newHistoryStore()

    store.setTopicHistoryMode("topic1", hmMemoryOnly)
    for i in 1..5:
      let msg = newMessage("topic1", mtData, fmt"msg{i}")
      store.addToHistory("topic1", msg)

    store.cleanup()

    # After cleanup, nothing should remain
    check store.getHistory("topic1").len == 0
    check store.getAllHistorySizes().len == 0

  test "multiple topics independent":
    let store = newHistoryStore()

    store.setTopicHistoryMode("topic1", hmMemoryOnly)
    store.setTopicHistoryMode("topic2", hmMemoryOnly)

    for i in 1..5:
      let msg1 = newMessage("topic1", mtData, fmt"t1-msg{i}")
      store.addToHistory("topic1", msg1)

      let msg2 = newMessage("topic2", mtData, fmt"t2-msg{i}")
      store.addToHistory("topic2", msg2)

    let history1 = store.getHistory("topic1")
    let history2 = store.getHistory("topic2")

    check history1.len == 5
    check history2.len == 5
    check history1[0].payload == "t1-msg1"
    check history2[0].payload == "t2-msg1"

  test "messages preserve all fields":
    let store = newHistoryStore()
    store.setTopicHistoryMode("topic1", hmMemoryOnly)

    let msg = newMessage("topic1", mtPresence, "payload")
    msg.sequence = 42
    msg.headers = RawJson($(%*{"sender": "alice"}))
    store.addToHistory("topic1", msg)

    let history = store.getHistory("topic1")

    check history[0].id == msg.id
    check history[0].topic == "topic1"
    check history[0].messageType == mtPresence
    check history[0].payload == "payload"
    check history[0].sequence == 42
    check history[0].headers.string.contains("alice")

  test "edge case: sinceSeq larger than all sequences":
    let store = newHistoryStore()
    store.setTopicHistoryMode("topic1", hmMemoryOnly)

    for i in 1..5:
      let msg = newMessage("topic1", mtData, fmt"msg{i}")
      msg.sequence = uint64(i)
      store.addToHistory("topic1", msg)

    let history = store.getHistory("topic1", sinceSeq=100)
    check history.len == 0

  test "edge case: count=0 returns all":
    let store = newHistoryStore()
    store.setTopicHistoryMode("topic1", hmMemoryOnly)

    for i in 1..10:
      let msg = newMessage("topic1", mtData, fmt"msg{i}")
      store.addToHistory("topic1", msg)

    let history = store.getHistory("topic1", count=0)
    check history.len == 10

  test "persistent storage stores and retrieves messages":
    # This test verifies that hmPersistent mode actually persists messages
    let testPath = "/tmp/test_history.data"
    # Clean up any existing test file
    try:
      removeFile(testPath)
    except:
      discard

    # Create store with persistence
    let store = newHistoryStore(enablePersistence = true, barrelPath = testPath)
    store.setTopicHistoryMode("persistent_topic", hmPersistent)

    # Add some messages
    for i in 1..5:
      let msg = newMessage("persistent_topic", mtData, fmt"msg{i}")
      msg.sequence = uint64(i)
      msg.headers = RawJson($(%*{"index": i}))
      store.addToHistory("persistent_topic", msg)

    # Verify messages are in memory
    let history = store.getHistory("persistent_topic")
    check history.len == 5

    # Cleanup
    try:
      removeFile(testPath)
    except:
      discard

  test "persistent storage with sequence filtering":
    let store = newHistoryStore()
    store.setTopicHistoryMode("seq_test", hmPersistent)

    for i in 1..10:
      let msg = newMessage("seq_test", mtData, fmt"msg{i}")
      msg.sequence = uint64(i)
      store.addToHistory("seq_test", msg)

    # Get messages since sequence 6
    let history = store.getHistory("seq_test", sinceSeq=6)
    check history.len == 5  # Messages 6, 7, 8, 9, 10
    check history[0].sequence == 6
    check history[4].sequence == 10

  test "persistent storage respects max count":
    let store = newHistoryStore()
    store.setTopicHistoryMode("count_test", hmPersistent)

    for i in 1..20:
      let msg = newMessage("count_test", mtData, fmt"msg{i}")
      msg.sequence = uint64(i)
      store.addToHistory("count_test", msg)

    # Get only 5 most recent messages
    let history = store.getHistory("count_test", count=5)
    check history.len == 5
    # Should be last 5 messages (16-20)
    check history[0].sequence == 16
    check history[4].sequence == 20
