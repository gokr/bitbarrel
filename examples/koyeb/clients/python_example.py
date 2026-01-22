#!/usr/bin/env python3
"""
BitBarrel Python Client Example for Koyeb Deployment
Demonstrates connecting to BitBarrel on Koyeb with authentication
"""

import asyncio
import websockets
import json
import os
from typing import Optional, Any


class BitBarrelClient:
    """Simple WebSocket client for BitBarrel"""

    def __init__(self, endpoint: str, token: Optional[str] = None):
        self.endpoint = endpoint
        self.token = token
        self.websocket = None
        self.request_id = 0

    async def connect(self) -> None:
        """Connect to BitBarrel WebSocket endpoint"""
        headers = {}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"

        self.websocket = await websockets.connect(
            self.endpoint,
            extra_headers=headers
        )
        print(f"✓ Connected to {self.endpoint}")

    async def disconnect(self) -> None:
        """Disconnect from BitBarrel"""
        if self.websocket:
            await self.websocket.close()
            print("✓ Disconnected")

    async def set(self, key: str, value: str) -> bool:
        """Set a key-value pair"""
        self.request_id += 1
        request = {
            "jsonrpc": "2.0",
            "method": "set",
            "params": [key, value],
            "id": self.request_id
        }

        await self.websocket.send(json.dumps(request))
        response = await self.websocket.recv()
        result = json.loads(response)

        if "error" in result and result["error"] is not None:
            print(f"✗ Error setting {key}: {result['error']}")
            return False

        return True

    async def get(self, key: str) -> Optional[str]:
        """Get a value by key"""
        self.request_id += 1
        request = {
            "jsonrpc": "2.0",
            "method": "get",
            "params": [key],
            "id": self.request_id
        }

        await self.websocket.send(json.dumps(request))
        response = await self.websocket.recv()
        result = json.loads(response)

        if "error" in result and result["error"] is not None:
            print(f"✗ Error getting {key}: {result['error']}")
            return None

        return result.get("result")

    async def delete(self, key: str) -> bool:
        """Delete a key"""
        self.request_id += 1
        request = {
            "jsonrpc": "2.0",
            "method": "delete",
            "params": [key],
            "id": self.request_id
        }

        await self.websocket.send(json.dumps(request))
        response = await self.websocket.recv()
        result = json.loads(response)

        if "error" in result and result["error"] is not None:
            print(f"✗ Error deleting {key}: {result['error']}")
            return False

        return True

    async def keys(self, pattern: str = "") -> list:
        """Get keys matching pattern"""
        self.request_id += 1
        request = {
            "jsonrpc": "2.0",
            "method": "keys",
            "params": [pattern],
            "id": self.request_id
        }

        await self.websocket.send(json.dumps(request))
        response = await self.websocket.recv()
        result = json.loads(response)

        if "error" in result and result["error"] is not None:
            print(f"✗ Error getting keys: {result['error']}")
            return []

        return result.get("result", [])


async def demo_basic_operations(client: BitBarrelClient):
    """Demonstrate basic CRUD operations"""
    print("\n📦 Basic Operations Demo")
    print("─" * 40)

    # Set some data
    print("\n1. Setting user data...")
    await client.set("user:1001:name", "Alice Smith")
    await client.set("user:1001:email", "alice@example.com")
    await client.set("user:1001:role", "admin")
    print("   ✓ User data stored")

    # Read the data
    print("\n2. Reading user data...")
    name = await client.get("user:1001:name")
    email = await client.get("user:1001:email")
    print(f"   Name: {name}")
    print(f"   Email: {email}")

    # Update data
    print("\n3. Updating user's email...")
    await client.set("user:1001:email", "alice.smith@example.com")
    updated_email = await client.get("user:1001:email")
    print(f"   Updated email: {updated_email}")

    # Delete data
    print("\n4. Deleting user's role...")
    await client.delete("user:1001:role")
    role = await client.get("user:1001:role")
    print(f"   Role after deletion: {role}")


async def demo_session_management(client: BitBarrelClient):
    """Demonstrate session management"""
    print("\n🎫 Session Management Demo")
    print("─" * 40)

    session_id = "sess_12345"
    timestamp = str(int(asyncio.get_event_loop().time()))

    print("\n1. Creating session...")
    await client.set(f"session:{session_id}:user_id", "1001")
    await client.set(f"session:{session_id}:created_at", timestamp)
    await client.set(f"session:{session_id}:ip", "192.168.1.100")
    print("   ✓ Session created")

    print("\n2. Reading session data...")
    user_id = await client.get(f"session:{session_id}:user_id")
    created_at = await client.get(f"session:{session_id}:created_at")
    ip = await client.get(f"session:{session_id}:ip")
    print(f"   User ID: {user_id}")
    print(f"   Created: {created_at}")
    print(f"   IP: {ip}")

    print("\n3. Updating session...")
    await client.set(f"session:{session_id}:last_access", timestamp)
    print("   ✓ Session updated")

    print("\n4. Cleaning up session...")
    keys = await client.keys(f"session:{session_id}:*")
    for key in keys:
        await client.delete(key)
    print(f"   ✓ Deleted {len(keys)} session keys")


async def demo_feature_flags(client: BitBarrelClient):
    """Demonstrate feature flag management"""
    print("\n🚩 Feature Flags Demo")
    print("─" * 40)

    features = {
        "new_dashboard": True,
        "dark_mode": True,
        "beta_api": False,
        "experimental_ml": True
    }

    print("\n1. Setting feature flags...")
    for feature, enabled in features.items():
        await client.set(f"feature:{feature}", str(enabled).lower())
        status = "✓" if enabled else "✗"
        print(f"   {status} {feature}: {'enabled' if enabled else 'disabled'}")

    print("\n2. Checking feature flags...")
    for feature in features.keys():
        value = await client.get(f"feature:{feature}")
        enabled = value == "true"
        status = "✓" if enabled else "✗"
        print(f"   {status} {feature}: {'enabled' if enabled else 'disabled'}")

    print("\n3. Rolling out new feature...")
    await client.set("feature:new_dashboard", "true")
    print("   ✓ New dashboard enabled for all users")


async def demo_counter(client: BitBarrelClient):
    """Demonstrate counter operations"""
    print("\n🧮 Counter Demo")
    print("─" * 40)

    print("\n1. Page view counter...")
    page = "/home"
    for i in range(1, 6):
        current = await client.get(f"pageviews:{page}")
        count = int(current) if current else 0
        await client.set(f"pageviews:{page}", str(count + 1))
        print(f"   View {i}: Total views = {count + 1}")

    print("\n2. Unique visitors...")
    visitor_id = "user_1001"
    visitors = await client.get(f"visitors:{page}")
    visitor_list = json.loads(visitors) if visitors else []
    if visitor_id not in visitor_list:
        visitor_list.append(visitor_id)
        await client.set(f"visitors:{page}", json.dumps(visitor_list))
    print(f"   ✓ Visitor {visitor_id} added")
    print(f"   Total unique visitors: {len(visitor_list)}")


async def demo_performance_test(client: BitBarrelClient):
    """Simple performance test"""
    print("\n⚡ Performance Test")
    print("─" * 40)

    print("\nRunning 100 operations...")
    start_time = asyncio.get_event_loop().time()

    # Mix of writes and reads
    for i in range(50):
        await client.set(f"perf:test:{i}", f"value_{i}")
        await client.get(f"perf:test:{i % 25}")

    elapsed = asyncio.get_event_loop().time() - start_time
    ops_per_sec = 100 / elapsed

    print(f"   ✓ Completed 100 operations in {elapsed:.3f}s")
    print(f"   ✓ Throughput: {ops_per_sec:.0f} ops/sec")

    # Cleanup
    keys = await client.keys("perf:test:*")
    for key in keys:
        await client.delete(key)
    print(f"   ✓ Cleaned up {len(keys)} test keys")


async def demo_error_handling(client: BitBarrelClient):
    """Demonstrate error handling"""
    print("\n⚠️  Error Handling Demo")
    print("─" * 40)

    print("\n1. Getting non-existent key...")
    result = await client.get("nonexistent:key")
    print(f"   Result: {result}")

    print("\n2. Handling connection errors...")
    try:
        # This will fail if we're already connected
        await client.connect()
    except Exception as e:
        print(f"   Expected error: {str(e)[:50]}...")


async def main():
    """Main demo function"""
    # Configuration - update these for your deployment
    KOYEB_ENDPOINT = os.environ.get("BITBARREL_ENDPOINT",
                                    "wss://my-bitbarrel.koyeb.app")
    KOYEB_TOKEN = os.environ.get("BITBARREL_JWT_SECRET")

    print(f"Connecting to BitBarrel at {KOYEB_ENDPOINT}")
    if KOYEB_TOKEN:
        print("Using authentication token")

    # Create client
    client = BitBarrelClient(KOYEB_ENDPOINT, KOYEB_TOKEN)

    try:
        # Connect
        await client.connect()

        # Run demos
        await demo_basic_operations(client)
        await demo_session_management(client)
        await demo_feature_flags(client)
        await demo_counter(client)
        await demo_performance_test(client)
        await demo_error_handling(client)

        # List all keys we created
        print("\n📋 Final Key Listing")
        print("─" * 40)
        keys = await client.keys("")
        print(f"\nTotal keys in database: {len(keys)}")
        for key in sorted(keys)[:10]:  # Show first 10
            print(f"   - {key}")
        if len(keys) > 10:
            print(f"   ... and {len(keys) - 10} more")

    except Exception as e:
        print(f"\n✗ Error: {e}")

    finally:
        # Disconnect
        await client.disconnect()

    print("\n✓ Demo completed successfully!")


if __name__ == "__main__":
    # Check if websockets is installed
    try:
        import websockets
    except ImportError:
        print("✗ websockets package not found")
        print("Install with: pip install websockets")
        exit(1)

    # Run the demo
    asyncio.run(main())
