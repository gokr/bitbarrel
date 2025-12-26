#!/usr/bin/env python3
"""Reference traversal example."""

from bitbarrel import Client


def main():
    client = Client()
    client.connect()

    try:
        client.create_barrel("social")
        client.use_barrel("social")
        print("Using social barrel")

        # Store interconnected data
        data = {
            "user:alice": '{"name":"Alice","friend":"user:bob","colleague":"user:charlie"}',
            "user:bob": '{"name":"Bob","friend":"user:alice"}',
            "user:charlie": '{"name":"Charlie","colleague":"user:alice"}',
        }

        for key, value in data.items():
            client.set(key, value)
            print(f"Stored: {key}")

        # Traverse friends
        print("\nFriends of Alice:")
        results = client.traverse("user:alice", "->friend", includeFullData=True)
        for result in results:
            print(f"  {result.path}: {result.value}")

        # Traverse all references
        print("\nAll references from Alice:")
        results = client.traverse("user:alice", "*", includeFullData=True)
        for result in results:
            print(f"  {result.path}: {result.value}")

        # Traverse with convenience method
        print("\nFriends (traverse_path):")
        results = client.traverse_path("user:alice", "->friend")
        for result in results:
            print(f"  {result.key}: {result.value}")

        print("\n=== Traversal completed successfully ===")

    finally:
        client.close()


if __name__ == "__main__":
    main()
