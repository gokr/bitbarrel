#define _DEFAULT_SOURCE
#include <bitbarrel.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// Helper to print current time
static void print_time(void) {
    time_t now = time(NULL);
    struct tm* t = localtime(&now);
    printf("%02d:%02d:%02d ", t->tm_hour, t->tm_min, t->tm_sec);
}

int main(void) {
    printf("BitBarrel C Client PubSub Chat Example (12-step pattern)\n");
    printf("========================================================\n\n");

    // Step 1: Connect to BitBarrel server (localhost:9876)
    print_time();
    printf("1. Connecting to BitBarrel server...\n");

    // Initialize library
    if (bb_init() != BB_OK) {
        fprintf(stderr, "Failed to initialize BitBarrel library\n");
        return 1;
    }

    // Create configuration
    BBConfig config = bb_config_default();
    config.url = "ws://localhost:9876";
    config.timeout_ms = 10000;

    // Create client
    BBClient* client = bb_client_create(&config);
    if (!client) {
        fprintf(stderr, "Failed to create client\n");
        bb_cleanup();
        return 1;
    }

    // Connect to server
    if (bb_connect(client) != BB_OK) {
        fprintf(stderr, "Failed to connect: %s\n", bb_get_last_error(client));
        bb_client_destroy(client);
        bb_cleanup();
        return 1;
    }
    print_time();
    printf("✓ Connected to BitBarrel server\n\n");

    int result = 0; // 0 = success, 1 = error

    // Step 2: Setup chat storage barrel
    print_time();
    printf("2. Setting up chat storage barrel...\n");
    const char* barrel_name = "chat_storage";
    BBResult res = bb_create_barrel(client, barrel_name, BM_CRITBIT);
    if (res == BB_OK) {
        print_time();
        printf("✓ Created chat_storage barrel (bmCritBit mode)\n");
    } else if (res == BB_BARREL_EXISTS) {
        print_time();
        printf("✓ Using existing chat_storage barrel\n");
    } else {
        fprintf(stderr, "Failed to create barrel: %s\n", bb_get_last_error(client));
        result = 1;
        goto cleanup;
    }

    if (bb_use_barrel(client, barrel_name) != BB_OK) {
        fprintf(stderr, "Failed to use barrel: %s\n", bb_get_last_error(client));
        result = 1;
        goto cleanup;
    }
    print_time();
    printf("✓ Using chat_storage barrel\n\n");

    // Step 3: Subscribe to "room:general" with options (history replay, presence)
    print_time();
    printf("3. Subscribing to \"room:general\"...\n");
    if (bb_subscribe(client, "room:general") != BB_OK) {
        fprintf(stderr, "Failed to subscribe: %s\n", bb_get_last_error(client));
        result = 1;
        goto cleanup;
    }
    print_time();
    printf("✓ Subscribed to \"room:general\"\n\n");

    // Step 4: Publish 5 chat messages from 5 users
    print_time();
    printf("4. Publishing 5 chat messages from 5 users...\n");
    const char* users[] = {"Alice", "Bob", "Charlie", "Diana", "Eve"};
    const char* messages[] = {
        "Hello everyone!",
        "How are you all doing?",
        "This chat system is great!",
        "Anyone working on interesting projects?",
        "Let's schedule a meetup next week.",
    };

    for (int i = 0; i < 5; i++) {
        // Simple JSON construction
        char data[256];
        snprintf(data, sizeof(data),
                 "{\"user\":\"%s\",\"message\":\"%s\",\"timestamp\":%ld}",
                 users[i], messages[i], (long)time(NULL));

        if (bb_publish(client, "room:general", data) != BB_OK) {
            fprintf(stderr, "Failed to publish message %d: %s\n", i+1, bb_get_last_error(client));
            result = 1;
            goto cleanup;
        }
        print_time();
        printf("  %s: %s\n", users[i], messages[i]);

        // Small delay between messages
#ifdef _WIN32
        Sleep(100);
#else
        usleep(100000);
#endif
    }
    print_time();
    printf("✓ Published 5 messages\n\n");

    // Step 5: Retrieve and display message history
    print_time();
    printf("5. Retrieving message history...\n");
    BBMessage** history_msgs = NULL;
    size_t history_count = 0;
    if (bb_get_history(client, "room:general", 10, 0, &history_msgs, &history_count) == BB_OK) {
        print_time();
        printf("✓ Retrieved %zu messages from history:\n", history_count);
        for (size_t i = 0; i < history_count; i++) {
            BBMessage* msg = history_msgs[i];
            printf("  [%zu] %s: %s\n", i+1, msg->topic ? msg->topic : "?",
                   msg->data ? msg->data : "?");
            bb_free_message(msg);
        }
        free(history_msgs); // Free the array of pointers
    } else {
        fprintf(stderr, "Failed to get history: %s\n", bb_get_last_error(client));
        // Continue anyway
    }
    printf("\n");

    // Step 6: Subscribe to "room:*" pattern (using watch_key for pattern subscription)
    print_time();
    printf("6. Subscribing to \"room:*\" pattern...\n");
    if (bb_watch_key(client, "room:*") != BB_OK) {
        fprintf(stderr, "Failed to subscribe to pattern: %s\n", bb_get_last_error(client));
        result = 1;
        goto cleanup;
    }
    print_time();
    printf("✓ Subscribed to \"room:*\" pattern\n\n");

    // Step 7: Publish to different rooms (tech, random)
    print_time();
    printf("7. Publishing to different rooms...\n");
    const char* room_messages[][3] = {
        {"room:tech", "Alice", "New TypeScript features are awesome!"},
        {"room:random", "Bob", "Random thought: pineapples on pizza?"},
    };

    for (int i = 0; i < 2; i++) {
        char data[256];
        snprintf(data, sizeof(data),
                 "{\"user\":\"%s\",\"message\":\"%s\",\"timestamp\":%ld}",
                 room_messages[i][1], room_messages[i][2], (long)time(NULL));

        if (bb_publish(client, room_messages[i][0], data) != BB_OK) {
            fprintf(stderr, "Failed to publish to room %s: %s\n",
                    room_messages[i][0], bb_get_last_error(client));
            result = 1;
            goto cleanup;
        }
        print_time();
        printf("  Published to %s: %s: %s\n", room_messages[i][0],
               room_messages[i][1], room_messages[i][2]);
    }
    printf("\n");

    // Step 8: Query subscribers in "room:general"
    print_time();
    printf("8. Querying subscribers in \"room:general\"...\n");
    char** subscribers = NULL;
    size_t sub_count = 0;
    if (bb_list_subscribers(client, "room:general", &subscribers, &sub_count) == BB_OK) {
        print_time();
        printf("✓ Subscribers in \"room:general\": %zu subscribers\n", sub_count);
        for (size_t i = 0; i < sub_count; i++) {
            printf("  %zu. %s\n", i+1, subscribers[i]);
            bb_free_string(subscribers[i]);
        }
        bb_free_string_array(subscribers, sub_count);
    } else {
        fprintf(stderr, "Failed to list subscribers: %s\n", bb_get_last_error(client));
    }
    printf("\n");

    // Step 9: Check presence information
    print_time();
    printf("9. Checking presence information...\n");
    char* presence_json = NULL;
    if (bb_get_presence(client, "room:general", &presence_json) == BB_OK) {
        print_time();
        printf("✓ Presence information: %s\n", presence_json);
        bb_free_string(presence_json);
    } else {
        fprintf(stderr, "Failed to get presence: %s\n", bb_get_last_error(client));
    }
    printf("\n");

    // Step 10: Get history with sequence filtering (sinceSeq=3)
    print_time();
    printf("10. Getting history since sequence 3...\n");
    BBMessage** history_since3 = NULL;
    size_t history_since3_count = 0;
    if (bb_get_history(client, "room:general", 10, 3, &history_since3, &history_since3_count) == BB_OK) {
        print_time();
        printf("✓ Retrieved %zu messages since sequence 3:\n", history_since3_count);
        for (size_t i = 0; i < history_since3_count; i++) {
            BBMessage* msg = history_since3[i];
            printf("  [seq ?] %s: %s\n", msg->topic ? msg->topic : "?",
                   msg->data ? msg->data : "?");
            bb_free_message(msg);
        }
        free(history_since3);
    } else {
        fprintf(stderr, "Failed to get history since seq 3: %s\n", bb_get_last_error(client));
    }
    printf("\n");

    // Step 11: Show history per room
    print_time();
    printf("11. Showing history per room...\n");
    const char* rooms[] = {"room:general", "room:tech", "room:random"};
    for (int i = 0; i < 3; i++) {
        BBMessage** room_history = NULL;
        size_t room_history_count = 0;
        if (bb_get_history(client, rooms[i], 3, 0, &room_history, &room_history_count) == BB_OK) {
            print_time();
            printf("  %s: %zu messages\n", rooms[i], room_history_count);
            if (room_history_count > 0) {
                BBMessage* last_msg = room_history[room_history_count - 1];
                printf("    Last: %s\n", last_msg->data ? last_msg->data : "?");
            }
            for (size_t j = 0; j < room_history_count; j++) {
                bb_free_message(room_history[j]);
            }
            free(room_history);
        } else {
            printf("  %s: No history available\n", rooms[i]);
        }
    }
    printf("\n");

    // Step 12: Cleanup (unsubscribe, close)
    print_time();
    printf("12. Cleaning up...\n");
    if (bb_unsubscribe(client, "room:general") != BB_OK) {
        fprintf(stderr, "Failed to unsubscribe: %s\n", bb_get_last_error(client));
    }
    if (bb_unwatch_key(client, "room:*") != BB_OK) {
        fprintf(stderr, "Failed to unwatch pattern: %s\n", bb_get_last_error(client));
    }
    print_time();
    printf("✓ Unsubscribed from all topics\n");

cleanup:
    // Close connection
    bb_disconnect(client);
    bb_client_destroy(client);
    bb_cleanup();

    print_time();
    printf("✓ Closed connection\n\n");

    if (result == 0) {
        print_time();
        printf("=== Example completed successfully! ===\n");
    } else {
        print_time();
        printf("=== Example completed with errors ===\n");
    }

    return result;
}