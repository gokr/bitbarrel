#ifndef BITBARREL_H
#define BITBARREL_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle for BitBarrel client connection
typedef struct BitBarrelClient BBClient;

// Barrel index modes (matching Nim implementation)
typedef enum {
    BM_HASH = 0,        // Hash index (default)
    BM_CRITBIT = 1      // CritBit tree for range queries
} BBMode;

// Result codes
typedef enum {
    BB_OK = 0,
    BB_ERROR = -1,
    BB_NOT_FOUND = 1,
    BB_NO_BARREL = 4,
    BB_BARREL_EXISTS = 5,
    BB_INVALID_REQUEST = 6,
    BB_CONNECTION_ERROR = 7,
    BB_TIMEOUT = 8,
    BB_PROTOCOL_ERROR = 9
} BBResult;

// Configuration structure
typedef struct {
    const char* url;                    // WebSocket URL (ws:// or wss://)
    int timeout_ms;                     // Request timeout in milliseconds
    int max_retries;                    // Max reconnection attempts
    bool enable_auto_reconnect;         // Auto-reconnect on connection loss
} BBConfig;

// Pub/Sub message structure
typedef struct {
    char* id;           // Message ID
    char* topic;        // Topic name
    char* data;         // Message data
    int64_t timestamp;  // Unix timestamp in milliseconds
} BBMessage;

// Range query result
typedef struct {
    char** keys;        // Array of keys
    char** values;      // Array of values
    size_t count;       // Number of items
    char* next_cursor;  // Cursor for next page (NULL if no more)
    bool has_more;      // True if more items available
} BBRangeResult;

// Initialize library (call once per process)
BBResult bb_init(void);

// Cleanup library
void bb_cleanup(void);

// Create default configuration
BBConfig bb_config_default(void);

// Create client connection
BBClient* bb_client_create(const BBConfig* config);

// Destroy client connection
void bb_client_destroy(BBClient* client);

// Connection management
BBResult bb_connect(BBClient* client);
BBResult bb_disconnect(BBClient* client);
bool bb_is_connected(const BBClient* client);

// Barrel operations
BBResult bb_create_barrel(BBClient* client, const char* name, BBMode mode);
BBResult bb_open_barrel(BBClient* client, const char* name);
BBResult bb_close_barrel(BBClient* client);
BBResult bb_use_barrel(BBClient* client, const char* name);
BBResult bb_list_barrels(BBClient* client, char*** barrels, size_t* count);

// Key-Value operations
BBResult bb_set(BBClient* client, const char* key, const char* value, int ttl);
char* bb_get(BBClient* client, const char* key);  // Returns NULL if not found
BBResult bb_delete(BBClient* client, const char* key);
bool bb_exists(BBClient* client, const char* key);
BBResult bb_count(BBClient* client, int64_t* count);

// Range queries (only for BM_CRITBIT mode)
BBResult bb_items_in_range(BBClient* client, const char* start_key, const char* end_key,
                          size_t limit, const char* cursor, BBRangeResult** result);
BBResult bb_items_with_prefix(BBClient* client, const char* prefix,
                             size_t limit, const char* cursor, BBRangeResult** result);
void bb_free_range_result(BBRangeResult* result);

// Pub/Sub operations
BBResult bb_subscribe(BBClient* client, const char* topic);
BBResult bb_unsubscribe(BBClient* client, const char* topic);
BBResult bb_publish(BBClient* client, const char* topic, const char* data);
BBResult bb_list_subscribers(BBClient* client, const char* topic, char*** subscribers, size_t* count);
BBResult bb_list_topics(BBClient* client, char*** topics, size_t* count);
BBResult bb_get_history(BBClient* client, const char* topic, int limit, int since_seq, BBMessage*** messages, size_t* count);
BBResult bb_get_presence(BBClient* client, const char* topic, char** presence_json);

// Message polling (non-blocking check)
BBMessage* bb_poll_message(BBClient* client);

// Wait for message (blocking with timeout)
BBMessage* bb_wait_message(BBClient* client, int timeout_ms);

// Free message (must be called for all received messages)
void bb_free_message(BBMessage* msg);

// Key watching (protocol v1.1)
BBResult bb_watch_key(BBClient* client, const char* pattern);
BBResult bb_unwatch_key(BBClient* client, const char* pattern);

// Range query operations
BBResult bb_items_in_range(BBClient* client, const char* start_key, const char* end_key,
                          size_t limit, const char* cursor, BBRangeResult** result);
BBResult bb_items_with_prefix(BBClient* client, const char* prefix,
                             size_t limit, const char* cursor, BBRangeResult** result);

// Utility functions
void bb_free_string(char* str);
void bb_free_string_array(char** array, size_t count);
const char* bb_get_last_error(const BBClient* client);

// Message processing callback for async usage
typedef void (*BBMessageCallback)(const BBMessage* msg, void* userdata);
BBResult bb_set_message_callback(BBClient* client, BBMessageCallback callback, void* userdata);

#ifdef __cplusplus
}
#endif

#endif // BITBARREL_H
