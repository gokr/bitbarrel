## Test Pub/Sub Core Types
##
## Tests for Message, Topic, Subscription, Presence, and other core types

import std/[unittest, json, sets, tables, os]
import ../../src/pubsub/pubsub

suite "PubSub Core Types":
  test "newMessage creates valid message":
    let msg = newMessage("test:topic", mtData, "test payload")

    check msg.id.len > 0
    check msg.topic == "test:topic"
    check msg.messageType == mtData
    check msg.payload == "test payload"
    check msg.timestamp > 0
    check msg.sequence == 0  # Not set yet

  test "newMessage with headers":
    let headers = %*{"sender": "alice", "priority": 1}
    let msg = newMessage("test:topic", mtData, "payload", headers)

    check msg.headers != nil
    check msg.headers["sender"].getStr() == "alice"
    check msg.headers["priority"].getInt() == 1

  test "Message UUID uniqueness":
    let msg1 = newMessage("topic", mtData, "p1")
    let msg2 = newMessage("topic", mtData, "p2")

    check msg1.id != msg2.id

  test "Message toJson/fromJson roundtrip":
    let original = newMessage("test:topic", mtData, "test payload")
    original.sequence = 42

    let jsonNode = toJson(original)
    let restored = fromJson(jsonNode)

    check restored.id == original.id
    check restored.topic == original.topic
    check restored.messageType == original.messageType
    check restored.payload == original.payload
    check restored.timestamp == original.timestamp
    check restored.sequence == original.sequence

  test "Message toJson with headers":
    let headers = %*{"sender": "bob"}
    let original = newMessage("topic", mtData, "payload", headers)
    original.sequence = 10

    let jsonNode = toJson(original)
    let restored = fromJson(jsonNode)

    check restored.headers["sender"].getStr() == "bob"

  test "newTopic creates valid topic":
    let topic = newTopic("chat:room1")

    check topic.name == "chat:room1"
    check topic.sequence == 0
    check topic.createdAt > 0
    check topic.messageCount == 0
    check topic.subscribers.len == 0

  test "newTopic with custom config":
    var config = defaultTopicConfig()
    config.maxSubscribers = 5
    config.historyEnabled = true

    let topic = newTopic("chat:room1", config)

    check topic.config.maxSubscribers == 5
    check topic.config.historyEnabled == true

  test "Topic addSubscriber":
    let topic = newTopic("chat:room1")

    check topic.addSubscriber("sub1")
    check topic.addSubscriber("sub2")
    check topic.subscribers.len == 2
    check "sub1" in topic.subscribers
    check "sub2" in topic.subscribers

  test "Topic addSubscriber duplicate":
    let topic = newTopic("chat:room1")

    check topic.addSubscriber("sub1")
    check topic.addSubscriber("sub1")  # Adding again is ok
    check topic.subscribers.len == 1

  test "Topic addSubscriber respects maxSubscribers":
    var config = defaultTopicConfig()
    config.maxSubscribers = 2

    let topic = newTopic("chat:room1", config)

    check topic.addSubscriber("sub1")
    check topic.addSubscriber("sub2")
    check not topic.addSubscriber("sub3")  # Should fail
    check topic.subscribers.len == 2

  test "Topic removeSubscriber":
    let topic = newTopic("chat:room1")

    check topic.addSubscriber("sub1")
    check topic.addSubscriber("sub2")
    check topic.removeSubscriber("sub1")
    check topic.subscribers.len == 1
    check "sub2" in topic.subscribers

  test "Topic removeSubscriber non-existent":
    let topic = newTopic("chat:room1")

    check not topic.removeSubscriber("non-existent")

  test "Topic subscriberCount":
    let topic = newTopic("chat:room1")

    check topic.subscriberCount() == 0
    discard topic.addSubscriber("sub1")
    check topic.subscriberCount() == 1
    discard topic.addSubscriber("sub2")
    check topic.subscriberCount() == 2

  test "newPresenceInfo creates valid presence":
    let presence = newPresenceInfo("chat:room1")

    check presence.topic == "chat:room1"
    check presence.members.len == 0
    check presence.lastUpdate > 0

  test "PresenceInfo addMember":
    let presence = newPresenceInfo("chat:room1")

    presence.addMember(1'u64, "alice")

    check presence.members.len == 1
    check "1" in presence.members
    check presence.members["1"].username == "alice"
    check presence.members["1"].clientId == 1'u64

  test "PresenceInfo addMember with metadata":
    let presence = newPresenceInfo("chat:room1")
    let metadata = %*{"status": "online"}

    presence.addMember(1'u64, "alice", metadata)

    check presence.members["1"].metadata["status"].getStr() == "online"

  test "PresenceInfo removeMember":
    let presence = newPresenceInfo("chat:room1")

    presence.addMember(1'u64, "alice")
    check presence.removeMember(1'u64)
    check presence.members.len == 0

  test "PresenceInfo removeMember non-existent":
    let presence = newPresenceInfo("chat:room1")

    check not presence.removeMember(999'u64)

  test "PresenceInfo updatePing":
    let presence = newPresenceInfo("chat:room1")

    presence.addMember(1'u64, "alice")
    let oldPing = presence.members["1"].lastPing

    sleep(50)  # Wait to ensure timestamp changes
    check presence.updatePing(1'u64)

    check presence.members["1"].lastPing > oldPing

  test "PresenceInfo updatePing non-existent":
    let presence = newPresenceInfo("chat:room1")

    check not presence.updatePing(999'u64)

  test "PresenceInfo memberCount":
    let presence = newPresenceInfo("chat:room1")

    check presence.memberCount() == 0
    presence.addMember(1'u64, "alice")
    check presence.memberCount() == 1
    presence.addMember(2'u64, "bob")
    check presence.memberCount() == 2

  test "PresenceMember toJson":
    let presence = newPresenceInfo("chat:room1")
    let metadata = %*{"status": "online"}
    presence.addMember(1'u64, "alice", metadata)

    let member = presence.members["1"]
    let jsonNode = toJson(member)

    check jsonNode["clientId"].getInt() == 1
    check jsonNode["username"].getStr() == "alice"
    check jsonNode["metadata"]["status"].getStr() == "online"

  test "PresenceInfo toJson":
    let presence = newPresenceInfo("chat:room1")
    presence.addMember(1'u64, "alice")
    presence.addMember(2'u64, "bob")

    let jsonNode = toJson(presence)

    check jsonNode["topic"].getStr() == "chat:room1"
    check jsonNode["members"].len == 2
    check jsonNode["memberCount"].getInt() == 2

  test "newHeartbeatTracker creates valid tracker":
    let tracker = newHeartbeatTracker(30000, 5000)

    check tracker.timeoutMs == 30000
    check tracker.checkIntervalMs == 5000
    check tracker.clientLastSeen.len == 0

  test "HeartbeatTracker updateHeartbeat":
    let tracker = newHeartbeatTracker()

    tracker.updateHeartbeat(1'u64)
    check 1'u64 in tracker.clientLastSeen
    check tracker.clientLastSeen[1'u64] > 0

  test "HeartbeatTracker shouldRemoveClient timeout":
    let tracker = newHeartbeatTracker(timeoutMs = 100)

    tracker.updateHeartbeat(1'u64)
    check not tracker.shouldRemoveClient(1'u64)

    sleep(200)  # Wait 2x timeout
    check tracker.shouldRemoveClient(1'u64)

  test "HeartbeatTracker shouldRemoveClient non-existent":
    let tracker = newHeartbeatTracker()

    check not tracker.shouldRemoveClient(999'u64)

  test "HeartbeatTracker removeClient":
    let tracker = newHeartbeatTracker()

    tracker.updateHeartbeat(1'u64)
    check tracker.removeClient(1'u64)
    check 1'u64 notin tracker.clientLastSeen

  test "HeartbeatTracker removeClient non-existent":
    let tracker = newHeartbeatTracker()

    check not tracker.removeClient(999'u64)

  test "HeartbeatTracker removeStaleClients":
    let tracker = newHeartbeatTracker(timeoutMs = 100)

    tracker.updateHeartbeat(1'u64)
    tracker.updateHeartbeat(2'u64)
    tracker.updateHeartbeat(3'u64)

    sleep(200)  # Wait 2x timeout

    let stale = tracker.removeStaleClients()

    check stale.len == 3
    check 1'u64 in stale
    check 2'u64 in stale
    check 3'u64 in stale
    check tracker.clientLastSeen.len == 0

  test "defaultSubscriptionOptions has correct defaults":
    let options = defaultSubscriptionOptions()

    check not options.enableKvEvents
    check not options.enablePresence
    check not options.replayHistory

  test "defaultTopicConfig has correct defaults":
    let config = defaultTopicConfig()

    check config.maxSubscribers == 0
    check not config.historyEnabled
    check config.historyMode == hmNone
    check config.historyMaxMessages == 100
    check config.historyRetentionHours == 24
    check not config.persistenceEnabled

  test "defaultPubSubConfig has correct defaults":
    let config = defaultPubSubConfig()

    check config.enabled
    check config.maxTopics == 0
    check config.maxSubscriptionsPerClient == 0
    check config.heartbeatTimeoutMs == 30000
    check config.heartbeatCheckIntervalMs == 5000
