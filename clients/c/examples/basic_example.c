#include <bitbarrel.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    printf("BitBarrel C Client Basic Example\n");
    printf("=================================\n\n");

    // Initialize library
    if (bb_init() != BB_OK) {
        fprintf(stderr, "Failed to initialize BitBarrel library\n");
        return 1;
    }
    printf("✓ Library initialized\n");

    // Create configuration
    BBConfig config = bb_config_default();
    config.url = "ws://localhost:7687";
    config.timeout_ms = 5000;

    // Create client
    BBClient* client = bb_client_create(&config);
    if (!client) {
        fprintf(stderr, "Failed to create client\n");
        bb_cleanup();
        return 1;
    }
    printf("✓ Client created\n");

    // Connect to server
    if (bb_connect(client) != BB_OK) {
        fprintf(stderr, "Failed to connect: %s\n", bb_get_last_error(client));
        bb_client_destroy(client);
        bb_cleanup();
        return 1;
    }
    printf("✓ Connected to server\n");

    // Create a barrel
    const char* barrel_name = "test_barrel";
    if (bb_create_barrel(client, barrel_name, BM_HASH) == BB_OK) {
        printf("✓ Created barrel: %s\n", barrel_name);
    } else if (bb_get_last_error(client)) {
        printf("ℹ Barrel may already exist: %s\n", barrel_name);
    }

    // Open barrel
    if (bb_open_barrel(client, barrel_name) != BB_OK) {
        fprintf(stderr, "Failed to open barrel: %s\n", bb_get_last_error(client));
        bb_disconnect(client);
        bb_client_destroy(client);
        bb_cleanup();
        return 1;
    }
    printf("✓ Opened barrel\n");

    // Use barrel
    if (bb_use_barrel(client, barrel_name) != BB_OK) {
        fprintf(stderr, "Failed to use barrel: %s\n", bb_get_last_error(client));
        bb_disconnect(client);
        bb_client_destroy(client);
        bb_cleanup();
        return 1;
    }
    printf("✓ Using barrel\n");

    // Set some key-value pairs
    const char* keys[] = {"user:1", "user:2", "user:3"};
    const char* values[] = {"Alice", "Bob", "Charlie"};
    int num_pairs = 3;

    for (int i = 0; i < num_pairs; i++) {
        if (bb_set(client, keys[i], values[i], -1) == BB_OK) {
            printf("✓ Set: %s = %s\n", keys[i], values[i]);
        } else {
            fprintf(stderr, "✗ Failed to set %s: %s\n", keys[i], bb_get_last_error(client));
        }
    }

    // Get values back
    printf("\nRetrieving values:\n");
    for (int i = 0; i < num_pairs; i++) {
        char* value = bb_get(client, keys[i]);
        if (value) {
            printf("✓ Got: %s = %s\n", keys[i], value);
            bb_free_string(value);
        } else {
            printf("✗ Key not found: %s\n", keys[i]);
        }
    }

    // Check existence
    printf("\nChecking existence:\n");
    for (int i = 0; i < num_pairs; i++) {
        if (bb_exists(client, keys[i])) {
            printf("✓ Key exists: %s\n", keys[i]);
        } else {
            printf("✗ Key not found: %s\n", keys[i]);
        }
    }

    // Count keys
    int64_t count;
    if (bb_count(client, &count) == BB_OK) {
        printf("\n✓ Barrel contains %ld keys\n", count);
    }

    // List all barrels
    printf("\nListing barrels:\n");
    char** barrels;
    size_t barrel_count;
    if (bb_list_barrels(client, &barrels, &barrel_count) == BB_OK) {
        for (size_t i = 0; i < barrel_count; i++) {
            printf("  - %s\n", barrels[i]);
        }
        bb_free_string_array(barrels, barrel_count);
    }

    // Delete a key
    printf("\nDeleting key: %s\n", keys[0]);
    if (bb_delete(client, keys[0]) == BB_OK) {
        printf("✓ Deleted successfully\n");

        // Verify deletion
        if (!bb_exists(client, keys[0])) {
            printf("✓ Key no longer exists\n");
        }
    }

    // Close barrel
    if (bb_close_barrel(client) == BB_OK) {
        printf("\n✓ Closed barrel\n");
    }

    // Disconnect
    bb_disconnect(client);
    printf("✓ Disconnected from server\n");

    // Cleanup
    bb_client_destroy(client);
    bb_cleanup();
    printf("\n✓ Cleanup complete\n");

    printf("\nExample completed successfully!\n");
    return 0;
}
