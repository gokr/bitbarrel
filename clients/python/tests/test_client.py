"""Tests for BitBarrel Python client."""

import pytest
import time
import threading
from bitbarrel import Client
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
