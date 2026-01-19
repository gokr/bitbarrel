#!/usr/bin/env python3
"""
BitBarrel PubSub Chat Room Example

Demonstrates real-time chat with history replay, pattern subscriptions,
presence tracking, and query operations following the 12-step pattern.
"""

import json
import time
from bitbarrel import Client
from bitbarrel.errors import BarrelExistsError


def pubsub_chat_example():
    print("=== BitBarrel PubSub Chat Room Example (12-step pattern) ===\n")

    # Step 1: Connect to BitBarrel server (localhost:9876)
    print("1. Connecting to BitBarrel server...")
    client = Client(host="localhost", port=9876)
    client.connect()
    print("✓ Connected to BitBarrel server\n")

    try:
        # Step 2: Setup chat storage barrel
        print("2. Setting up chat storage barrel...")
        try:
            client.create_barrel("chat_storage")
            print("✓ Created chat_storage barrel")
        except BarrelExistsError:
            # Barrel might already exist
            print("✓ Using existing chat_storage barrel")
        client.use_barrel("chat_storage")
        print("✓ Using chat_storage barrel\n")

        # Step 3: Subscribe to "room:general" with options (history replay, presence)
        print("3. Subscribing to 'room:general'...")
        from bitbarrel.protocol import SubscriptionOptions
        subscription_options = SubscriptionOptions(replay_history=True, enable_presence=True)
        sub_id_general = client.subscribe("room:general", subscription_options)
        print("✓ Subscribed to 'room:general' with history replay and presence tracking\n")

        # Step 4: Publish 5 chat messages from 5 users
        print("4. Publishing 5 chat messages from 5 users...")
        users = ["Alice", "Bob", "Charlie", "Diana", "Eve"]
        messages = [
            "Hello everyone!",
            "How are you all doing?",
            "This chat system is great!",
            "Anyone working on interesting projects?",
            "Let's schedule a meetup next week.",
        ]

        for i in range(5):
            user = users[i]
            message = messages[i]
            data = json.dumps({
                "user": user,
                "message": message,
                "timestamp": int(time.time() * 1000),
            })
            client.publish("room:general", data)
            print(f"  {user}: {message}")
            time.sleep(0.1)  # Small delay between messages
        print("✓ Published 5 messages\n")

        # Step 5: Retrieve and display message history
        print("5. Retrieving message history...")
        history = client.get_history("room:general", limit=10)
        print(f"✓ Retrieved {len(history)} messages from history:")
        for idx, msg in enumerate(history):
            try:
                data = json.loads(msg["data"])
                print(f"  [{idx + 1}] {data['user']}: {data['message']}")
            except:
                print(f"  [{idx + 1}] {msg['data']}")
        print()

        # Step 6: Subscribe to "room:*" pattern
        print("6. Subscribing to 'room:*' pattern...")
        sub_id_pattern = client.subscribe("room:*")
        print("✓ Subscribed to 'room:*' pattern\n")

        # Step 7: Publish to different rooms (tech, random)
        print("7. Publishing to different rooms...")
        room_messages = [
            {"room": "room:tech", "user": "Alice", "message": "New TypeScript features are awesome!"},
            {"room": "room:random", "user": "Bob", "message": "Random thought: pineapples on pizza?"},
        ]
        for rm in room_messages:
            data = json.dumps({
                "user": rm["user"],
                "message": rm["message"],
                "timestamp": int(time.time() * 1000),
            })
            client.publish(rm["room"], data)
            print(f"  Published to {rm['room']}: {rm['user']}: {rm['message']}")
        print()

        # Step 8: Query subscribers in "room:general"
        print("8. Querying subscribers in 'room:general'...")
        subscribers = client.list_subscribers("room:general")
        print(f"✓ Subscribers in 'room:general': {len(subscribers)} subscribers")
        for idx, sub in enumerate(subscribers):
            print(f"  {idx + 1}. {sub}")
        print()

        # Step 9: Check presence information
        print("9. Checking presence information...")
        presence = client.get_presence("room:general")
        print("✓ Presence information:")
        print(f"  Active subscribers: {presence.get('active_subscribers', 'N/A')}")
        print(f"  Total messages: {presence.get('total_messages', 'N/A')}")
        last_activity = presence.get('last_activity')
        if last_activity:
            print(f"  Last activity: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(last_activity / 1000))}")
        print()

        # Step 10: Get history with sequence filtering (since_seq=3)
        print("10. Getting history since sequence 3...")
        history_since_3 = client.get_history("room:general", limit=10, since_seq=3)
        print(f"✓ Retrieved {len(history_since_3)} messages since sequence 3:")
        for idx, msg in enumerate(history_since_3):
            try:
                data = json.loads(msg["data"])
                print(f"  [seq {msg.get('sequence', 'N/A')}] {data['user']}: {data['message']}")
            except:
                print(f"  [seq {msg.get('sequence', 'N/A')}] {msg['data']}")
        print()

        # Step 11: Show history per room
        print("11. Showing history per room...")
        rooms = ["room:general", "room:tech", "room:random"]
        for room in rooms:
            try:
                room_history = client.get_history(room, limit=3)
                print(f"  {room}: {len(room_history)} messages")
                if room_history:
                    last_msg = room_history[-1]
                    try:
                        data = json.loads(last_msg["data"])
                        print(f"    Last: {data['user']}: {data['message']}")
                    except:
                        print(f"    Last: {last_msg['data']}")
            except Exception as e:
                print(f"  {room}: No history available ({e})")
        print()

        # Step 12: Cleanup (unsubscribe, close)
        print("12. Cleaning up...")
        client.unsubscribe(sub_id_general)
        client.unsubscribe(sub_id_pattern)
        print("✓ Unsubscribed from all topics")
        client.close()
        print("✓ Closed connection\n")

        print("=== Example completed successfully! ===\n")

    except Exception as error:
        print(f"Error during example: {error}")
        # Try to close connection on error
        try:
            client.close()
        except:
            pass
        raise


if __name__ == "__main__":
    pubsub_chat_example()