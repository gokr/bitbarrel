#!/usr/bin/env python3
"""Range and prefix query examples."""

from bitbarrel import Client


def main():
    client = Client()
    client.connect()

    print("Connected to BitBarrel server")

    try:
        # Create ordered barrel (bmCritBit mode)
        config = '{"mode": "bmCritBit"}'
        client.create_barrel("ordered", config)
        client.use_barrel("ordered")
        print("Using ordered barrel (bmCritBit mode)")

        # Store sorted data
        users = [
            ("user:001", "Alice"),
            ("user:002", "Bob"),
            ("user:003", "Charlie"),
            ("user:004", "Diana"),
            ("user:005", "Eve"),
        ]

        for key, value in users:
            client.set(key, value)
            print(f"Stored: {key}")

        # Range query
        print("\nRange query [user:002, user:005):")
        result = client.range_query("user:002", "user:005")
        for key, value in result.items:
            print(f"  {key} => {value}")
        print(f"  Cursor: '{result.nextCursor}', Has more: {result.hasMore}")

        # Prefix query with pagination
        print("\nPrefix query for 'user:' with pagination:")
        cursor = ""
        page = 0
        while True:
            result = client.prefix_query("user:", limit=2, cursor=cursor)
            if not result.items:
                break

            page += 1
            print(f"  Page {page}:")
            for key, value in result.items:
                print(f"    {key} => {value}")

            if not result.hasMore:
                break
            cursor = result.nextCursor

        # Range count
        count = client.range_count("user:000", "user:999")
        print(f"\nCount in range [user:000, user:999): {count}")

        # Using helpers
        print("\nUsing helper function get_all_in_range:")
        from bitbarrel.helpers import get_all_in_range

        all_items = get_all_in_range(client, "user:000", "user:999")
        for key, value in all_items:
            print(f"  {key} => {value}")

        print("\n=== Range queries completed successfully ===")

    finally:
        client.close()


if __name__ == "__main__":
    main()
