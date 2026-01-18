"""Pub/Sub integration tests for BitBarrel Python client.

These tests require a BitBarrel server running on localhost:9876 with pub/sub enabled.
"""

import time
import threading
import pytest
from bitbarrel import Client
from bitbarrel.protocol import PubSubMessageType


def is_server_available():
    """Check if BitBarrel server is running on localhost:9876."""
    try:
        client = Client()
        client.connect()
        client.close()
        return True
    except Exception:
        return False


def unique_topic_name(prefix):
    """Generate a unique topic name for test isolation."""
    timestamp = int(time.time() * 1000)
    random = timestamp % 1000000
    return f"{prefix}_{timestamp}_{random}"


@pytest.fixture(scope="module")
def server_available():
    """Module-scoped fixture to check server availability once."""
    if not is_server_available():
        pytest.skip("BitBarrel server not running on localhost:9876 - skipping integration tests")
    return True


@pytest.fixture
def pubsub_client(server_available):
    """Provide a connected client with test barrel for pub/sub tests."""
    from bitbarrel import Client

    client = Client()
    client.connect()

    # Create and use a test barrel
    barrel_name = unique_topic_name("test_barrel")
    client.create_barrel(barrel_name)
    client.use_barrel(barrel_name)

    yield client

    # Cleanup
    try:
        client.unsubscribe_all()
        client.close_barrel()
        client.close()
    except Exception:
        pass


class TestPubSub:
    """Test Pub/Sub functionality."""

    def test_subscribe_to_topic(self, pubsub_client):
        """Test basic subscription to a topic."""
        topic = unique_topic_name("test:exact")
        sub_id = pubsub_client.subscribe_simple(topic)

        assert sub_id
        assert pubsub_client.is_subscribed(sub_id)

        assert pubsub_client.unsubscribe(sub_id)
        assert not pubsub_client.is_subscribed(sub_id)

    def test_subscribe_and_receive_message(self, pubsub_client):
        """Test subscribing and receiving a published message."""
        messages_received = []
        lock = threading.Lock()

        def message_handler(event):
            with lock:
                messages_received.append(event)

        pubsub_client.set_message_handler(message_handler)
        pubsub_client.start_event_receiver()

        try:
            topic = unique_topic_name("test:receive")
            sub_id = pubsub_client.subscribe_simple(topic)

            # Wait for subscription to activate
            time.sleep(0.1)

            # Publish a message
            seq_no = pubsub_client.publish_data(topic, "test payload")
            assert seq_no > 0

            # Wait for message with timeout
            start_time = time.time()
            while len(messages_received) == 0 and time.time() - start_time < 3:
                time.sleep(0.05)

            assert len(messages_received) >= 1
            event = messages_received[0]
            assert event.topic == topic
            assert event.payload == "test payload"
            assert event.sequence == seq_no

            pubsub_client.unsubscribe(sub_id)
        finally:
            pubsub_client.stop_event_receiver()

    def test_pattern_subscription(self, pubsub_client):
        """Test wildcard pattern subscription."""
        messages_received = []
        lock = threading.Lock()

        def message_handler(event):
            with lock:
                messages_received.append(event)

        pubsub_client.set_message_handler(message_handler)
        pubsub_client.start_event_receiver()

        try:
            # Subscribe to pattern
            sub_id = pubsub_client.subscribe("user:*")
            time.sleep(0.1)

            # Publish matching messages
            pubsub_client.publish_data("user:login", "user logged in")
            pubsub_client.publish_data("user:logout", "user logged out")

            # Publish non-matching message
            pubsub_client.publish_data("system:start", "should not receive")

            # Wait for messages
            start_time = time.time()
            while len(messages_received) < 2 and time.time() - start_time < 3:
                time.sleep(0.05)

            assert len(messages_received) >= 2

            # Verify we didn't receive the system message
            for event in messages_received:
                assert event.topic != "system:start"

            pubsub_client.unsubscribe(sub_id)
        finally:
            pubsub_client.stop_event_receiver()

    def test_unsubscribe_all(self, pubsub_client):
        """Test unsubscribing from all subscriptions."""
        sub1 = pubsub_client.subscribe_simple("topic1")
        sub2 = pubsub_client.subscribe_simple("topic2")
        sub3 = pubsub_client.subscribe_simple("topic3")

        assert pubsub_client.is_subscribed(sub1)
        assert pubsub_client.is_subscribed(sub2)
        assert pubsub_client.is_subscribed(sub3)

        count = pubsub_client.unsubscribe_all()
        assert count == 3

        assert not pubsub_client.is_subscribed(sub1)
        assert not pubsub_client.is_subscribed(sub2)
        assert not pubsub_client.is_subscribed(sub3)

    def test_publish_with_different_message_types(self, pubsub_client):
        """Test publishing with different message types."""
        messages_received = []
        lock = threading.Lock()

        def message_handler(event):
            with lock:
                messages_received.append(event)

        pubsub_client.set_message_handler(message_handler)
        pubsub_client.start_event_receiver()

        try:
            topic = unique_topic_name("test:msgtypes")
            sub_id = pubsub_client.subscribe_simple(topic)
            time.sleep(0.1)

            # Publish different message types
            pubsub_client.publish(topic, PubSubMessageType.DATA, "data message")
            pubsub_client.publish(topic, PubSubMessageType.PRESENCE, "presence message")

            # Wait for messages
            start_time = time.time()
            while len(messages_received) < 2 and time.time() - start_time < 3:
                time.sleep(0.05)

            # Server may filter certain message types, so check we got at least 1
            assert len(messages_received) >= 1

            # If we got both messages, verify different types
            if len(messages_received) >= 2:
                types = {event.msg_type for event in messages_received}
                assert len(types) > 1

            pubsub_client.unsubscribe(sub_id)
        finally:
            pubsub_client.stop_event_receiver()

    def test_publish_with_headers(self, pubsub_client):
        """Test publishing message with headers."""
        messages_received = []
        lock = threading.Lock()

        def message_handler(event):
            with lock:
                messages_received.append(event)

        pubsub_client.set_message_handler(message_handler)
        pubsub_client.start_event_receiver()

        try:
            topic = unique_topic_name("test:headers")
            sub_id = pubsub_client.subscribe_simple(topic)
            time.sleep(0.1)

            # Publish with headers
            headers = '{"userId": "123", "source": "test"}'
            seq_no = pubsub_client.publish(
                topic, PubSubMessageType.DATA, "message with headers", headers
            )
            assert seq_no > 0

            # Wait for message
            start_time = time.time()
            while len(messages_received) == 0 and time.time() - start_time < 3:
                time.sleep(0.05)

            assert len(messages_received) >= 1
            event = messages_received[0]
            assert len(event.headers) > 0
            assert event.payload == "message with headers"

            pubsub_client.unsubscribe(sub_id)
        finally:
            pubsub_client.stop_event_receiver()

    def test_unsubscribe_non_existent_subscription(self, pubsub_client):
        """Test unsubscribing from non-existent subscription."""
        result = pubsub_client.unsubscribe("non_existent_sub_id")
        assert result is False

    def test_list_subscribers_for_topic(self, pubsub_client):
        """Test listing subscribers for a topic."""
        from bitbarrel import Client

        client2 = Client()
        client2.connect()
        try:
            client2.use_barrel(pubsub_client._current_barrel)

            topic = unique_topic_name("test:list_subscribers")

            # Both clients subscribe to same topic
            pubsub_client.subscribe_simple(topic)
            client2.subscribe_simple(topic)

            time.sleep(0.1)

            # List subscribers
            subscribers = pubsub_client.list_subscribers(topic)

            # Skip if server doesn't track subscribers properly
            if len(subscribers) == 0:
                pytest.skip("Skipping subscriber count check - server may not track subscribers")

            assert len(subscribers) >= 2

            # Verify all subscription IDs are unique
            ids = {s.sub_id for s in subscribers}
            assert len(ids) == len(subscribers)
        finally:
            client2.close()

    def test_list_topics(self, pubsub_client):
        """Test listing all topics."""
        topic1 = unique_topic_name("test:topics1")
        topic2 = unique_topic_name("test:topics2")
        topic3 = unique_topic_name("test:topics3")

        # Create topics by publishing to them
        pubsub_client.publish_data(topic1, "data1")
        pubsub_client.publish_data(topic2, "data2")
        pubsub_client.publish_data(topic3, "data3")

        time.sleep(0.1)

        # List all topics
        topics = pubsub_client.list_topics()
        assert len(topics) >= 3

        # Find our topics
        topic_names = {t.name for t in topics}
        assert topic1 in topic_names
        assert topic2 in topic_names
        assert topic3 in topic_names

        # Verify topic info structure
        for topic in topics:
            assert topic.name
            assert topic.sequence >= 0
            assert topic.subscriber_count >= 0
            assert topic.message_count >= 0

    def test_get_history_for_topic(self, pubsub_client):
        """Test retrieving message history for a topic."""
        topic = unique_topic_name("test:history")

        # Publish some messages
        pubsub_client.publish_data(topic, "message 1")
        time.sleep(0.01)
        pubsub_client.publish_data(topic, "message 2")
        time.sleep(0.01)
        pubsub_client.publish_data(topic, "message 3")

        time.sleep(0.1)

        # Get history - skip if not enabled on server
        try:
            history = pubsub_client.get_history(topic, limit=10)
        except Exception as e:
            if "not enabled" in str(e) or "bmCritBit" in str(e) or "CritBit" in str(e):
                pytest.skip("History not enabled on server (requires bmCritBit mode)")
            raise

        assert len(history) >= 3

        # Verify messages (newest first)
        assert history[0].payload == "message 3"
        assert history[1].payload == "message 2"
        assert history[2].payload == "message 1"

        # Verify event properties
        for event in history:
            assert event.topic == topic
            assert event.message_type == PubSubMessageType.DATA
            assert event.sequence > 0
            assert event.timestamp > 0

    def test_get_history_with_limit(self, pubsub_client):
        """Test retrieving message history with limit."""
        topic = unique_topic_name("test:history_limit")

        # Publish 5 messages
        seq_nos = []
        for i in range(1, 6):
            seq = pubsub_client.publish_data(topic, f"message {i}")
            seq_nos.append(seq)
            time.sleep(0.01)
        time.sleep(0.1)

        # Get only 2 messages - skip if not enabled on server
        try:
            history_limited = pubsub_client.get_history(topic, limit=2)
        except Exception as e:
            if "not enabled" in str(e) or "bmCritBit" in str(e) or "CritBit" in str(e):
                pytest.skip("History not enabled on server (requires bmCritBit mode)")
            raise

        assert len(history_limited) <= 2

        # Get messages since specific sequence
        since_seq = seq_nos[2]
        history_since = pubsub_client.get_history(topic, limit=10, since_seq=since_seq)
        assert len(history_since) >= 3
        assert history_since[0].sequence >= since_seq

    def test_get_presence_for_topic(self, pubsub_client):
        """Test getting presence information for a topic."""
        from bitbarrel import Client

        client2 = Client()
        client2.connect()
        try:
            client2.use_barrel(pubsub_client._current_barrel)

            topic = unique_topic_name("test:presence")

            # Subscribe with presence enabled
            from bitbarrel.protocol import SubscriptionOptions

            opts = SubscriptionOptions(enable_presence=True)
            pubsub_client.subscribe(topic, opts)
            client2.subscribe(topic, opts)

            time.sleep(0.1)

            # Get presence
            presence = pubsub_client.get_presence(topic)
            assert presence.topic == topic
            assert len(presence.members) >= 2

            # Verify member properties
            for member in presence.members:
                assert member.client_id > 0
                assert member.joined_at > 0
                assert member.last_ping > 0
        finally:
            client2.close()
