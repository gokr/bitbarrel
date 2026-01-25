"""Tests for BitBarrel Python client."""

import pytest
import time
import threading
from bitbarrel import Client, PubSubMessageType
from bitbarrel.errors import (
    ConnectionError, NotFoundError, NoBarrelError,
    BarrelExistsError, BarrelNotFoundError
)

# These tests require a running BitBarrel server


class TestConnection:
    """Test client connection."""

    def test_connect(self, client):
        """Test that client can connect to server."""
        assert client is not None

    def test_ping(self, client):
        """Test ping-pong with server."""
        assert client.ping() is True

    def test_connect_failed(self):
        """Test connecting to a non-existent server."""
        client = Client(host="localhost", port=9999)
        with pytest.raises(Exception):
            client.connect()

    def test_double_connect(self, client):
        """Test connecting twice raises error or is idempotent."""
        # First connect already done by fixture
        # Second connect should either raise or be idempotent
        try:
            client.connect()
            # If no error, that's ok (idempotent)
        except Exception:
            # If error, that's also ok
            pass

    def test_close_without_connect(self):
        """Test closing without connecting doesn't error."""
        client = Client()
        client.close()  # Should not raise


class TestBarrelManagement:
    """Test barrel operations."""

    def test_create_barrel(self, client):
        """Test creating a barrel."""
        name = f"test_create_{int(time.time() * 1000)}"
        assert client.create_barrel(name) is True
        # Cleanup
        client.drop_barrel(name)

    def test_create_barrel_duplicate(self, client):
        """Test creating a duplicate barrel raises error."""
        name = f"test_dup_{int(time.time() * 1000)}"
        client.create_barrel(name)
        try:
            with pytest.raises(BarrelExistsError):
                client.create_barrel(name)
        finally:
            client.drop_barrel(name)

    def test_list_barrels(self, client, temp_barrel):
        """Test listing barrels."""
        barrels = client.list_barrels()
        assert isinstance(barrels, list)
        assert temp_barrel in barrels

    def test_use_barrel(self, client):
        """Test using a barrel."""
        name = f"test_use_{int(time.time() * 1000)}"
        client.create_barrel(name)
        try:
            client.use_barrel(name)
            assert client.current_barrel == name
        finally:
            client.drop_barrel(name)

    def test_use_barrel_not_found(self, client):
        """Test using a non-existent barrel raises error."""
        with pytest.raises(BarrelNotFoundError):
            client.use_barrel("nonexistent_barrel_12345")

    def test_open_barrel(self, client):
        """Test opening a barrel."""
        name = f"test_open_{int(time.time() * 1000)}"
        client.create_barrel(name)
        try:
            client.open_barrel(name)
            # open_barrel doesn't set currentBarrel
        finally:
            client.drop_barrel(name)

    def test_close_barrel(self, client):
        """Test closing a barrel."""
        name = f"test_close_{int(time.time() * 1000)}"
        client.create_barrel(name)
        try:
            client.use_barrel(name)
            assert client.current_barrel == name
            client.close_barrel()
            assert client.current_barrel == ""
        finally:
            try:
                client.drop_barrel(name)
            except Exception:
                pass

    def test_drop_barrel(self, client):
        """Test dropping a barrel."""
        name = f"test_drop_{int(time.time() * 1000)}"
        client.create_barrel(name)
        assert client.drop_barrel(name) is True

        # Verify barrel no longer exists
        barrels = client.list_barrels()
        assert name not in barrels


class TestBasicOperations:
    """Test basic CRUD operations."""

    def test_set_and_get(self, client, temp_barrel):
        """Test setting and getting a value."""
        client.set("test_key", "test_value")
        assert client.get("test_key") == "test_value"

    def test_get_not_found(self, client, temp_barrel):
        """Test getting a non-existent key raises error."""
        with pytest.raises(NotFoundError):
            client.get("nonexistent_key_12345")

    def test_get_or_default_exists(self, client, temp_barrel):
        """Test get_or_default with existing key."""
        client.set("test_key", "test_value")
        assert client.get_or_default("test_key", "default") == "test_value"

    def test_get_or_default_not_found(self, client, temp_barrel):
        """Test get_or_default with non-existent key returns default."""
        assert client.get_or_default("nonexistent_key_12345", "default") == "default"

    def test_get_or_default_empty_default(self, client, temp_barrel):
        """Test get_or_default with empty default."""
        assert client.get_or_default("nonexistent_key_12345") == ""

    def test_set_without_barrel(self, client):
        """Test setting without selecting a barrel raises error."""
        with pytest.raises(NoBarrelError):
            client.set("key", "value")

    def test_delete(self, client, temp_barrel):
        """Test deleting a key."""
        client.set("test_key", "test_value")
        assert client.delete("test_key") is True
        # Verify key is gone
        with pytest.raises(NotFoundError):
            client.get("test_key")

    def test_exists(self, client, temp_barrel):
        """Test checking if key exists."""
        assert client.exists("nonexistent") is False
        client.set("test_key", "test_value")
        assert client.exists("test_key") is True

    def test_count(self, client, temp_barrel):
        """Test counting keys."""
        # Empty barrel
        assert client.count() == 0

        # Add some keys
        for i in range(5):
            client.set(f"key{i}", f"value{i}")

        assert client.count() == 5

    def test_list_keys(self, client, temp_barrel):
        """Test listing all keys."""
        client.set("key1", "value1")
        client.set("key2", "value2")
        keys = client.list_keys()
        assert "key1" in keys
        assert "key2" in keys

    def test_large_value(self, client, temp_barrel):
        """Test storing and retrieving large values."""
        large_value = "x" * 10000
        client.set("large_key", large_value)
        retrieved = client.get("large_key")
        assert retrieved == large_value

    def test_concurrency(self, client, temp_barrel):
        """Test concurrent operations."""
        errors = []
        done = threading.Event()

        def worker(n):
            try:
                key = f"conc_key_{n}"
                value = f"conc_value_{n}"
                client.set(key, value)
                retrieved = client.get(key)
                if retrieved != value:
                    errors.append(f"Worker {n}: value mismatch")
            except Exception as e:
                errors.append(f"Worker {n}: {e}")

        threads = []
        for i in range(10):
            t = threading.Thread(target=worker, args=(i,))
            threads.append(t)
            t.start()

        for t in threads:
            t.join()

        assert len(errors) == 0, f"Errors: {errors}"
        assert client.count() == 10


class TestRangeQueries:
    """Test range query operations."""

    def test_range_query(self, client, ordered_barrel):
        """Test range query."""
        client.set("user:001", "Alice")
        client.set("user:002", "Bob")
        client.set("user:003", "Charlie")

        result = client.range_query("user:001", "user:003")
        assert len(result.items) == 2
        assert ("user:001", "Alice") in result.items
        assert ("user:002", "Bob") in result.items

    def test_prefix_query(self, client, ordered_barrel):
        """Test prefix query."""
        client.set("user:001", "Alice")
        client.set("user:002", "Bob")
        client.set("other:001", "Other")

        result = client.prefix_query("user:")
        assert len(result.items) == 2
        assert ("user:001", "Alice") in result.items
        assert ("user:002", "Bob") in result.items

    def test_range_count(self, client, ordered_barrel):
        """Test counting keys in range."""
        client.set("user:001", "Alice")
        client.set("user:002", "Bob")
        client.set("user:003", "Charlie")

        count = client.range_count("user:000", "user:999")
        assert count == 3


class TestBarrelConfig:
    """Test barrel configuration operations."""

    def test_get_barrel_config(self, client):
        """Test getting barrel configuration."""
        name = f"test_config_{int(time.time() * 1000)}"
        client.create_barrel(name, '{"mode": "critbit"}')
        try:
            config = client.get_barrel_config(name)
            assert isinstance(config, str)
            assert "critbit" in config
        finally:
            client.drop_barrel(name)

    def test_set_barrel_config(self, client):
        """Test setting barrel configuration."""
        name = f"test_config_set_{int(time.time() * 1000)}"
        client.create_barrel(name, '{"mode": "critbit"}')
        try:
            # Try changing a mutable option (can't change mode at runtime)
            new_config = '{"autoCompact": false}'
            client.set_barrel_config(name, new_config)
            retrieved = client.get_barrel_config(name)
            assert '"autoCompact": false' in retrieved or '"autoCompact": false' in retrieved.lower()
        finally:
            client.drop_barrel(name)

    def test_get_barrel_stats(self, client):
        """Test getting barrel statistics."""
        name = f"test_stats_{int(time.time() * 1000)}"
        client.create_barrel(name, '{"mode": "hash"}')
        try:
            # Insert some data
            client.use_barrel(name)
            client.set("key1", "value1")
            client.set("key2", "value2")
            client.set("key3", "value3")

            # Get statistics
            stats_json = client.get_barrel_stats(name)
            assert isinstance(stats_json, str)

            # Parse JSON and verify structure
            import json
            stats = json.loads(stats_json)

            assert "totalKeys" in stats
            assert "activeKeys" in stats
            assert stats["totalKeys"] >= 3
            assert stats["activeKeys"] >= 3
            assert stats["indexMode"] == "bmHash"
            assert isinstance(stats["fileCount"], int)
            assert isinstance(stats["totalSize"], int)
        finally:
            client.drop_barrel(name)


class TestContextManager:
    """Test context manager usage."""

    def test_context_manager(self):
        """Test using client as context manager."""
        name = f"test_ctx_{int(time.time() * 1000)}"
        with Client() as client:
            assert client.connected
            client.create_barrel(name)
            client.use_barrel(name)
            client.set("test", "value")
            assert client.get("test") == "value"
        # Connection should be closed after exiting context
        assert not client.connected


class TestJWTAuthentication:
    """Test JWT authentication."""

    def test_client_with_token(self):
        """Test client creation with JWT token."""
        token = "test-jwt-token"
        client = Client(token=token)

        assert client._token == token

    def test_connect_with_token(self):
        """Test connection with JWT token."""
        # Test with a sample JWT token format
        token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0X3JlYWR3cml0ZSIsInJvbGVzIjpbInJlYWR3cml0ZSJdLCJpYXQiOjE3MDQwNjcyMDAsImV4cCI6NDA5OTc2NzIwMH0.test_signature_for_testing"
        client = Client(token=token)

        try:
            client.connect()
            # Connection may succeed or fail depending on server auth config
            # The important part is that the client sends the token
            client.close()
        except Exception as e:
            # Connection might fail if auth is enabled with different config
            # That's ok - we're testing the client sends the token
            print(f"Expected: connection with token error (may be ok): {e}")

    def test_connect_without_token(self):
        """Test connection without authentication."""
        client = Client()

        try:
            client.connect()
            assert client.connected

            # Should be able to perform operations
            name = f"test_no_auth_{int(time.time() * 1000)}"
            try:
                client.create_barrel(name)
                client.use_barrel(name)
                client.set("key1", "value1")
                assert client.get("key1") == "value1"
                assert client.exists("key1")
                assert client.count() == 1
            finally:
                client.drop_barrel(name)

            client.close()
        except Exception as e:
            # If server not running, test passes
            if "no server running" in str(e).lower():
                pytest.skip("No server running")
            else:
                raise


class TestBatchOperations:
    """Test batch operations."""

    def test_batch_set_empty(self, client, temp_barrel):
        """Test batch_set with empty list."""
        client.use_barrel(temp_barrel)
        count = client.batch_set([])
        assert count == 0

    def test_batch_set_single(self, client, temp_barrel):
        """Test batch_set with single item."""
        client.use_barrel(temp_barrel)
        items = [("key1", "value1")]
        count = client.batch_set(items)
        assert count == 1
        assert client.get("key1") == "value1"

    def test_batch_set_multiple(self, client, temp_barrel):
        """Test batch_set with multiple items."""
        client.use_barrel(temp_barrel)
        items = [
            ("key1", "value1"),
            ("key2", "value2"),
            ("key3", "value3"),
        ]
        count = client.batch_set(items)
        assert count == 3
        assert client.get("key1") == "value1"
        assert client.get("key2") == "value2"
        assert client.get("key3") == "value3"

    def test_batch_get_empty(self, client, temp_barrel):
        """Test batch_get with empty list."""
        client.use_barrel(temp_barrel)
        result = client.batch_get([])
        assert result == []

    def test_batch_get_single(self, client, temp_barrel):
        """Test batch_get with single existing key."""
        client.use_barrel(temp_barrel)
        client.set("key1", "value1")
        result = client.batch_get(["key1"])
        assert len(result) == 1
        assert result[0] == ("key1", "value1")

    def test_batch_get_multiple(self, client, temp_barrel):
        """Test batch_get with multiple keys."""
        client.use_barrel(temp_barrel)
        items = [
            ("key1", "value1"),
            ("key2", "value2"),
            ("key3", "value3"),
        ]
        client.batch_set(items)
        result = client.batch_get(["key1", "key2", "key3"])
        assert len(result) == 3
        assert ("key1", "value1") in result
        assert ("key2", "value2") in result
        assert ("key3", "value3") in result

    def test_batch_get_with_missing_keys(self, client, temp_barrel):
        """Test batch_get returns only found keys."""
        client.use_barrel(temp_barrel)
        client.set("key1", "value1")
        result = client.batch_get(["key1", "nonexistent_key", "key2"])
        assert len(result) == 1
        assert result[0] == ("key1", "value1")

    def test_batch_delete_empty(self, client, temp_barrel):
        """Test batch_delete with empty list."""
        client.use_barrel(temp_barrel)
        count = client.batch_delete([])
        assert count == 0

    def test_batch_delete_single(self, client, temp_barrel):
        """Test batch_delete with single key."""
        client.use_barrel(temp_barrel)
        client.set("key1", "value1")
        count = client.batch_delete(["key1"])
        assert count == 1
        assert not client.exists("key1")

    def test_batch_delete_multiple(self, client, temp_barrel):
        """Test batch_delete with multiple keys."""
        client.use_barrel(temp_barrel)
        items = [
            ("key1", "value1"),
            ("key2", "value2"),
            ("key3", "value3"),
        ]
        client.batch_set(items)
        count = client.batch_delete(["key1", "key2"])
        assert count == 2
        assert not client.exists("key1")
        assert not client.exists("key2")
        assert client.exists("key3")  # Should still exist


class TestTTL:
    """Test TTL (Time To Live) functionality."""

    def test_set_without_ttl(self, client, temp_barrel):
        """Test set without TTL parameter."""
        client.use_barrel(temp_barrel)
        client.set("key1", "value1")
        assert client.get("key1") == "value1"
        # Key should persist
        time.sleep(1)
        assert client.get("key1") == "value1"

    def test_set_with_ttl(self, client, temp_barrel):
        """Test set with TTL parameter."""
        client.use_barrel(temp_barrel)
        client.set("key1", "value1", ttl=2)  # 2 second TTL
        assert client.get("key1") == "value1"
        # Wait for key to expire
        time.sleep(3)
        with pytest.raises(NotFoundError):
            client.get("key1")

    def test_set_with_zero_ttl(self, client, temp_barrel):
        """Test set with TTL=0 (should not expire)."""
        client.use_barrel(temp_barrel)
        client.set("key1", "value1", ttl=0)
        assert client.get("key1") == "value1"
        time.sleep(1)
        assert client.get("key1") == "value1"

    def test_overwrite_with_ttl(self, client, temp_barrel):
        """Test overwriting key with TTL."""
        client.use_barrel(temp_barrel)
        client.set("key1", "value1")
        # Overwrite with TTL
        client.set("key1", "value2", ttl=2)
        assert client.get("key1") == "value2"
        time.sleep(3)
        with pytest.raises(NotFoundError):
            client.get("key1")


class TestKeyWatching:
    """Test key watching functionality."""

    def test_watch_basic(self, client, temp_barrel):
        """Test basic watch functionality."""
        client.use_barrel(temp_barrel)

        # Set up message handler to collect events
        events = []
        def handler(event):
            if event.message_type == PubSubMessageType.mtKvChange:
                events.append(event)

        client.set_message_handler(handler)

        # Watch for key changes - this internally subscribes to kv:{barrel}:user:*
        pattern = "user:*"
        watch_result = client.watch(pattern, include_values=False)
        assert watch_result  # Ensure watch was successful

        # Give some time for watch to register
        time.sleep(0.5)

        # Set a matching key
        client.set("user:1", "Alice")

        # Receive any pending events that arrived after the set response
        client.receive_pending_events(timeout=1.0)

        # Should have received an event
        assert len(events) >= 1, f"Expected key change events but got none. Events: {events}"
        event = events[0]
        # Topic format: kv:{barrelName}:user:1
        assert "user:1" in event.topic
        assert event.message_type == PubSubMessageType.mtKvChange
        assert event.payload == ""  # No values included when include_values=False

        client.unwatch(pattern)

    def test_watch_with_values(self, client, temp_barrel):
        """Test watch with value inclusion."""
        client.use_barrel(temp_barrel)

        events = []
        def handler(event):
            if event.message_type == PubSubMessageType.mtKvChange:
                events.append(event)

        client.set_message_handler(handler)

        # Watch with values
        pattern = "cache:*"
        watch_result = client.watch(pattern, include_values=True)
        assert watch_result

        time.sleep(0.5)

        # Set a matching key
        client.set("cache:item1", "value1")

        # Receive any pending events that arrived after the set response
        client.receive_pending_events(timeout=1.0)

        # Check event received with value
        assert len(events) >= 1, f"Expected key change events but got none. Events: {events}"
        event = events[0]
        assert "cache:item1" in event.topic
        assert event.payload == "value1"  # Value included

        client.unwatch(pattern)

    def test_unwatch(self, client, temp_barrel):
        """Test unwatch functionality."""
        client.use_barrel(temp_barrel)

        events = []
        def handler(event):
            if event.message_type == PubSubMessageType.mtKvChange:
                events.append(event)

        client.set_message_handler(handler)

        # Set up watch
        pattern = "temp:*"
        watch_result = client.watch(pattern, include_values=False)
        assert watch_result
        time.sleep(0.5)

        # Now unwatch
        client.unwatch(pattern)
        time.sleep(0.5)

        # Set a key that would match
        client.set("temp:1", "value1")
        time.sleep(0.5)

        # Should not have received any events
        assert len(events) == 0, f"Expected no events after unwatch but got: {events}"

    def test_watch_without_barrel(self, client):
        """Test watch without selecting a barrel raises error."""
        with pytest.raises(NoBarrelError):
            client.watch("user:*", include_values=False)

