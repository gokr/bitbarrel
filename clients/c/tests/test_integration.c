#include <bitbarrel.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <assert.h>

// Generate a unique barrel name for testing
static void generate_unique_barrel_name(char* buffer, size_t size) {
    time_t t = time(NULL);
    snprintf(buffer, size, "test_barrel_%ld", t);
}

int main(void) {
    printf("BitBarrel C Client Integration Test\n");
    printf("====================================\n\n");

    // Initialize library
    BBResult result = bb_init();
    if (result != BB_OK) {
        fprintf(stderr, "Failed to initialize BitBarrel library\n");
        return 1;
    }
    printf("✓ Library initialized\n");

    // Create configuration - connect to localhost:9876/ws (test server WebSocket path)
    BBConfig config = bb_config_default();
    config.url = "ws://localhost:9876/ws";
    config.timeout_ms = 5000;
    config.max_retries = 3;
    config.enable_auto_reconnect = true;

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

    // Generate unique barrel name
    char barrel_name[64];
    generate_unique_barrel_name(barrel_name, sizeof(barrel_name));

    // Create a barrel
    if (bb_create_barrel(client, barrel_name, BM_HASH) == BB_OK) {
        printf("✓ Created barrel: %s\n", barrel_name);
    } else {
        fprintf(stderr, "Failed to create barrel: %s\n", bb_get_last_error(client));
        bb_disconnect(client);
        bb_client_destroy(client);
        bb_cleanup();
        return 1;
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

    // Test key-value operations
    const char* test_key = "integration_test_key";
    const char* test_value = "integration_test_value";

    // Set a key
    if (bb_set(client, test_key, test_value, -1) == BB_OK) {
        printf("✓ Set: %s = %s\n", test_key, test_value);
    } else {
        fprintf(stderr, "Failed to set key: %s\n", bb_get_last_error(client));
        bb_close_barrel(client);
        bb_disconnect(client);
        bb_client_destroy(client);
        bb_cleanup();
        return 1;
    }

    // Get the key back
    char* retrieved = bb_get(client, test_key);
    if (retrieved) {
        if (strcmp(retrieved, test_value) == 0) {
            printf("✓ Got: %s = %s\n", test_key, retrieved);
        } else {
            fprintf(stderr, "Retrieved value mismatch: expected '%s', got '%s'\n", test_value, retrieved);
            bb_free_string(retrieved);
            bb_close_barrel(client);
            bb_disconnect(client);
            bb_client_destroy(client);
            bb_cleanup();
            return 1;
        }
        bb_free_string(retrieved);
    } else {
        fprintf(stderr, "Failed to get key: %s\n", bb_get_last_error(client));
        bb_close_barrel(client);
        bb_disconnect(client);
        bb_client_destroy(client);
        bb_cleanup();
        return 1;
    }

    // Check existence
    if (bb_exists(client, test_key)) {
        printf("✓ Key exists: %s\n", test_key);
    } else {
        fprintf(stderr, "Key should exist but doesn't\n");
        bb_close_barrel(client);
        bb_disconnect(client);
        bb_client_destroy(client);
        bb_cleanup();
        return 1;
    }

    // Delete the key
    if (bb_delete(client, test_key) == BB_OK) {
        printf("✓ Deleted key: %s\n", test_key);
    } else {
        fprintf(stderr, "Failed to delete key: %s\n", bb_get_last_error(client));
        bb_close_barrel(client);
        bb_disconnect(client);
        bb_client_destroy(client);
        bb_cleanup();
        return 1;
    }

    // Verify deletion
    if (!bb_exists(client, test_key)) {
        printf("✓ Key no longer exists (as expected)\n");
    } else {
        fprintf(stderr, "Key still exists after deletion\n");
        bb_close_barrel(client);
        bb_disconnect(client);
        bb_client_destroy(client);
        bb_cleanup();
        return 1;
    }

    // Count keys (should be 0)
    int64_t count;
    if (bb_count(client, &count) == BB_OK) {
        printf("✓ Barrel contains %ld keys (expected 0)\n", count);
        if (count != 0) {
            fprintf(stderr, "Unexpected key count: %ld\n", count);
        }
    } else {
        fprintf(stderr, "Failed to count keys: %s\n", bb_get_last_error(client));
    }

    // Close barrel
    if (bb_close_barrel(client) == BB_OK) {
        printf("✓ Closed barrel\n");
    } else {
        fprintf(stderr, "Failed to close barrel: %s\n", bb_get_last_error(client));
    }

    // Disconnect
    bb_disconnect(client);
    printf("✓ Disconnected from server\n");

    // Cleanup
    bb_client_destroy(client);
    bb_cleanup();
    printf("✓ Cleanup complete\n");

    printf("\n✓ All integration tests passed!\n");
    return 0;
}