"""Tests for BitBarrel Python client."""

import pytest

# These tests require a running BitBarrel server


class TestConnection:
    """Test client connection."""

    def test_connect(self, client):
        """Test that client can connect to server."""
        assert client is not None

    def test_ping(self, client):
        """Test ping-pong with server."""
        assert client.ping() is True


class TestBarrelManagement:
    """Test barrel operations."""

    def test_create_barrel(self, client):
        """Test creating a barrel."""
        import time

        name = f"test_create_{int(time.time() * 1000)}"
        assert client.create_barrel(name) is True

    def test_list_barrels(self, client, temp_barrel):
        """Test listing barrels."""
        barrels = client.list_barrels()
        assert isinstance(barrels, list)
        assert temp_barrel in barrels

    def test_drop_barrel(self, client):
        """Test dropping a barrel."""
        import time

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

    def test_delete(self, client, temp_barrel):
        """Test deleting a key."""
        client.set("test_key", "test_value")
        assert client.delete("test_key") is True

    def test_exists(self, client, temp_barrel):
        """Test checking if key exists."""
        assert client.exists("nonexistent") is False
        client.set("test_key", "test_value")
        assert client.exists("test_key") is True

    def test_list_keys(self, client, temp_barrel):
        """Test listing all keys."""
        client.set("key1", "value1")
        client.set("key2", "value2")
        keys = client.list_keys()
        assert "key1" in keys
        assert "key2" in keys


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
