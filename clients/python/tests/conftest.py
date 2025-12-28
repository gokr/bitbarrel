"""Pytest configuration and fixtures for BitBarrel tests."""

import pytest
from bitbarrel import Client


@pytest.fixture
def client():
    """Provide a BitBarrel client for testing.

    The client is connected before each test and cleaned up after.
    """
    c = Client()
    c.connect()
    yield c
    c.close()


@pytest.fixture
def temp_barrel(client):
    """Provide a temporary barrel for testing.

    Creates a barrel with a unique name before the test
    and drops it after.
    """
    import time

    barrel_name = f"test_barrel_{int(time.time() * 1000)}"
    client.create_barrel(barrel_name)
    client.use_barrel(barrel_name)
    yield barrel_name

    # Clean up
    try:
        client.drop_barrel(barrel_name)
    except Exception:
        pass


@pytest.fixture
def ordered_barrel(client):
    """Provide a barrel with critbit mode for range queries."""
    import time

    barrel_name = f"test_ordered_{int(time.time() * 1000)}"
    client.create_barrel(barrel_name, '{"mode": "critbit"}')
    client.use_barrel(barrel_name)
    yield barrel_name

    # Clean up
    try:
        client.drop_barrel(barrel_name)
    except Exception:
        pass
