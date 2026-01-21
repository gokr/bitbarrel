#include <bitbarrel.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <assert.h>

// Test counters
static int tests_passed = 0;
static int tests_failed = 0;

// Helper macros
#define TEST_START(name) printf("  Testing: %s... ", name); fflush(stdout)
#define TEST_PASS() do { printf("PASS\n"); tests_passed++; fflush(stdout); } while(0)
#define TEST_FAIL(msg) do { printf("FAIL: %s\n", msg); tests_failed++; fflush(stdout); } while(0)

// Generate a unique barrel name for testing
static void generate_unique_barrel_name(char* buffer, size_t size, const char* prefix) {
    time_t t = time(NULL);
    snprintf(buffer, size, "%s_%ld_%d", prefix, t, rand() % 10000);
}

// Test suite: Basic Operations (minimal test to verify protocol works)
static void test_basic_operations(BBClient* client) {
    printf("\n=== Basic Operations ===\n");
    fflush(stdout);

    char barrel_name[64];
    generate_unique_barrel_name(barrel_name, sizeof(barrel_name), "basic_ops");

    // Test create barrel
    TEST_START("create barrel");
    if (bb_create_barrel(client, barrel_name, BM_HASH) == BB_OK) {
        TEST_PASS();
    } else {
        TEST_FAIL(bb_get_last_error(client));
        return;
    }

    // Test open barrel
    TEST_START("open barrel");
    if (bb_open_barrel(client, barrel_name) == BB_OK) {
        TEST_PASS();
    } else {
        TEST_FAIL(bb_get_last_error(client));
    }

    // Test use barrel
    TEST_START("use barrel");
    if (bb_use_barrel(client, barrel_name) == BB_OK) {
        TEST_PASS();
    } else {
        TEST_FAIL(bb_get_last_error(client));
    }

    // Test set
    TEST_START("set key-value");
    if (bb_set(client, "test_key", "test_value", -1) == BB_OK) {
        TEST_PASS();
    } else {
        TEST_FAIL(bb_get_last_error(client));
    }

    // Test get
    TEST_START("get key-value");
    char* value = bb_get(client, "test_key");
    if (value && strcmp(value, "test_value") == 0) {
        TEST_PASS();
        bb_free_string(value);
    } else {
        TEST_FAIL(value ? "Value mismatch" : bb_get_last_error(client));
        if (value) bb_free_string(value);
    }

    // Test exists
    TEST_START("exists");
    if (bb_exists(client, "test_key")) {
        TEST_PASS();
    } else {
        TEST_FAIL("Key should exist");
    }

    // Test count
    TEST_START("count");
    int64_t count = 0;
    if (bb_count(client, &count) == BB_OK && count == 1) {
        TEST_PASS();
    } else {
        char msg[64];
        snprintf(msg, sizeof(msg), "Expected 1, got %ld", count);
        TEST_FAIL(msg);
    }

    // Test delete
    TEST_START("delete");
    if (bb_delete(client, "test_key") == BB_OK) {
        TEST_PASS();
    } else {
        TEST_FAIL(bb_get_last_error(client));
    }

    // Verify deletion
    TEST_START("verify deleted");
    if (!bb_exists(client, "test_key")) {
        TEST_PASS();
    } else {
        TEST_FAIL("Key still exists");
    }

    // Test close barrel
    TEST_START("close barrel");
    if (bb_close_barrel(client) == BB_OK) {
        TEST_PASS();
    } else {
        TEST_FAIL(bb_get_last_error(client));
    }

    // Test list barrels
    TEST_START("list barrels");
    char** barrels = NULL;
    size_t barrel_count = 0;
    if (bb_list_barrels(client, &barrels, &barrel_count) == BB_OK) {
        int found = 0;
        for (size_t i = 0; i < barrel_count; i++) {
            if (strcmp(barrels[i], barrel_name) == 0) {
                found = 1;
                break;
            }
        }
        bb_free_string_array(barrels, barrel_count);
        if (found) {
            TEST_PASS();
        } else {
            TEST_FAIL("Barrel not in list");
        }
    } else {
        TEST_FAIL(bb_get_last_error(client));
    }

    // Test drop barrel
    TEST_START("drop barrel");
    if (bb_drop_barrel(client, barrel_name) == BB_OK) {
        TEST_PASS();
    } else {
        TEST_FAIL(bb_get_last_error(client));
    }
}

// Test suite: List Keys
static void test_list_keys(BBClient* client) {
    printf("\n=== List Keys ===\n");
    fflush(stdout);

    char barrel_name[64];
    generate_unique_barrel_name(barrel_name, sizeof(barrel_name), "list_keys");

    // Setup
    if (bb_create_barrel(client, barrel_name, BM_HASH) != BB_OK) {
        TEST_FAIL("Setup: create barrel failed");
        return;
    }
    if (bb_use_barrel(client, barrel_name) != BB_OK) {
        TEST_FAIL("Setup: use barrel failed");
        bb_drop_barrel(client, barrel_name);
        return;
    }

    // Add some keys
    bb_set(client, "key1", "value1", -1);
    bb_set(client, "key2", "value2", -1);
    bb_set(client, "key3", "value3", -1);

    // Test list keys
    TEST_START("list 3 keys");
    char** keys = NULL;
    size_t key_count = 0;
    if (bb_list_keys(client, &keys, &key_count) == BB_OK && key_count == 3) {
        TEST_PASS();
        bb_free_string_array(keys, key_count);
    } else {
        char msg[64];
        snprintf(msg, sizeof(msg), "Expected 3, got %zu", key_count);
        TEST_FAIL(msg);
        if (keys) bb_free_string_array(keys, key_count);
    }

    // Cleanup
    bb_close_barrel(client);
    bb_drop_barrel(client, barrel_name);
}

// Test suite: Range Queries
static void test_range_queries(BBClient* client) {
    printf("\n=== Range Queries (bmCritBit) ===\n");
    fflush(stdout);

    char barrel_name[64];
    generate_unique_barrel_name(barrel_name, sizeof(barrel_name), "range");

    // Setup with bmCritBit mode
    if (bb_create_barrel(client, barrel_name, BM_CRITBIT) != BB_OK) {
        TEST_FAIL("Setup: create critbit barrel failed");
        return;
    }
    if (bb_use_barrel(client, barrel_name) != BB_OK) {
        TEST_FAIL("Setup: use barrel failed");
        bb_drop_barrel(client, barrel_name);
        return;
    }

    // Add test data
    bb_set(client, "user:001", "Alice", -1);
    bb_set(client, "user:002", "Bob", -1);
    bb_set(client, "user:003", "Charlie", -1);
    bb_set(client, "product:001", "Widget", -1);

    // Test prefix query
    TEST_START("prefix query 'user:'");
    BBRangeResult* result = NULL;
    if (bb_items_with_prefix(client, "user:", 100, NULL, &result) == BB_OK) {
        if (result && result->count == 3) {
            TEST_PASS();
        } else {
            char msg[64];
            snprintf(msg, sizeof(msg), "Expected 3, got %zu", result ? result->count : 0);
            TEST_FAIL(msg);
        }
        bb_free_range_result(result);
    } else {
        TEST_FAIL(bb_get_last_error(client));
    }

    // Cleanup
    bb_close_barrel(client);
    bb_drop_barrel(client, barrel_name);
}

int main(void) {
    printf("BitBarrel C Client Integration Test\n");
    printf("====================================\n");
    fflush(stdout);

    srand(time(NULL));

    // Initialize library
    BBResult result = bb_init();
    if (result != BB_OK) {
        fprintf(stderr, "Failed to initialize BitBarrel library\n");
        return 1;
    }
    printf("Library initialized\n");
    fflush(stdout);

    // Create configuration
    BBConfig config = bb_config_default();
    config.url = "ws://localhost:9876/ws";
    config.timeout_ms = 10000;

    // Create client
    BBClient* client = bb_client_create(&config);
    if (!client) {
        fprintf(stderr, "Failed to create client\n");
        bb_cleanup();
        return 1;
    }
    printf("Client created\n");
    fflush(stdout);

    // Connect to server
    printf("Connecting to server...\n");
    fflush(stdout);
    if (bb_connect(client) != BB_OK) {
        fprintf(stderr, "Failed to connect: %s\n", bb_get_last_error(client));
        bb_client_destroy(client);
        bb_cleanup();
        return 1;
    }
    printf("Connected to server\n");
    fflush(stdout);

    // Run test suites
    test_basic_operations(client);
    test_list_keys(client);
    test_range_queries(client);

    // Disconnect
    bb_disconnect(client);
    printf("\nDisconnected from server\n");
    fflush(stdout);

    // Cleanup
    bb_client_destroy(client);
    bb_cleanup();
    printf("Cleanup complete\n");
    fflush(stdout);

    // Print summary
    printf("\n====================================\n");
    printf("Test Results: %d passed, %d failed\n", tests_passed, tests_failed);
    printf("====================================\n");

    if (tests_failed > 0) {
        printf("\nSome tests FAILED!\n");
        return 1;
    }

    printf("\nAll tests PASSED!\n");
    return 0;
}
