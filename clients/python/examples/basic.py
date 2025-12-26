#!/usr/bin/env python3
"""Basic CRUD operations example."""

from bitbarrel import Client, NotFoundError


def main():
    # Create client
    client = Client()
    client.connect()

    print("Connected to BitBarrel server")

    try:
        # Create and use barrel
        client.create_barrel("mydb")
        client.use_barrel("mydb")
        print("Using barrel: mydb")

        # Store data
        client.set("greeting", "Hello, BitBarrel!")
        print("Stored: greeting = Hello, BitBarrel!")

        # Retrieve data
        value = client.get("greeting")
        print(f"Retrieved: greeting = {value}")

        # Check existence
        exists = client.exists("greeting")
        print(f"Key 'greeting' exists: {exists}")

        # Delete key
        client.delete("greeting")
        print("Deleted key: greeting")

        # Verify deletion
        try:
            _ = client.get("greeting")
        except Exception:
            print("Confirmed: key 'greeting' no longer exists")

        # Store multiple items
        items = {
            "user:1": '{"name":"Alice","age":30}',
            "user:2": '{"name":"Bob","age":25}',
            "user:3": '{"name":"Charlie","age":35}',
        }

        for key, value in items.items():
            client.set(key, value)
            print(f"Stored: {key}")

        # List keys
        keys = client.list_keys()
        print(f"All keys: {keys}")

        print("\n=== Basic operations completed successfully ===")

    finally:
        client.close()


if __name__ == "__main__":
    main()
