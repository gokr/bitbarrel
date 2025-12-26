#!/usr/bin/env python3
"""Barrel management example."""

from bitbarrel import Client


def main():
    client = Client()
    client.connect()

    print("Connected to BitBarrel server")

    try:
        # List existing barrels
        barrels = client.list_barrels()
        print(f"Existing barrels: {barrels}")

        # Create barrels with different configurations
        configs = {
            "default": "",
            "ordered": '{"mode": "bmCritBit"}',
            "sync": '{"syncMode": "fsync"}',
        }

        for name, config in configs.items():
            client.create_barrel(name, config)
            print(f"Created barrel: {name}")

        # List all barrels
        barrels = client.list_barrels()
        print(f"All barrels: {barrels}")

        # Use a barrel and store data
        client.use_barrel("ordered")
        client.set("key1", "value1")
        client.set("key2", "value2")
        print("Stored data in 'ordered' barrel")

        # Check current barrel
        print(f"Current barrel: {client.currentBarrel}")

        # Close the barrel
        client.close_barrel("ordered")
        print("Closed barrel: ordered")

        # Drop a barrel
        client.drop_barrel("default")
        print("Dropped barrel: default")

        # List barrels again
        barrels = client.list_barrels()
        print(f"Remaining barrels: {barrels}")

        print("\n=== Barrel management completed successfully ===")

    finally:
        client.close()


if __name__ == "__main__":
    main()
