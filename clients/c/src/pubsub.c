#define _GNU_SOURCE

#include "../include/bitbarrel.h"
#include "bitbarrel_internal.h"
#include "protocol.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
#include <errno.h>

#define BUFFER_SIZE (64 * 1024)  // 64KB buffer

// Helper to extract field from JSON object
static char* extract_json_field(const char* json, const char* field) {
    char pattern[256];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", field);
    const char* start = strstr(json, pattern);
    if (!start) {
        // Try numeric field
        snprintf(pattern, sizeof(pattern), "\"%s\":", field);
        start = strstr(json, pattern);
        if (!start) return NULL;
        start += strlen(pattern);
        const char* end = strchr(start, ',');
        if (!end) end = strchr(start, '}');
        if (!end) return NULL;
        size_t len = end - start;
        char* result = malloc(len + 1);
        if (!result) return NULL;
        memcpy(result, start, len);
        result[len] = '\0';
        return result;
    }
    start += strlen(pattern);
    const char* end = strchr(start, '"');
    if (!end) return NULL;
    size_t len = end - start;
    char* result = malloc(len + 1);
    if (!result) return NULL;
    memcpy(result, start, len);
    result[len] = '\0';
    return result;
}

// Helper to count items in JSON array
static size_t count_json_array_items(const char* json) {
    size_t count = 0;
    const char* ptr = json;
    while (*ptr) {
        if (*ptr == '{') {
            count++;
        }
        ptr++;
    }
    return count;
}

// Simple message queue for Pub/Sub
struct MessageNode {
    BBMessage* msg;
    struct MessageNode* next;
};

typedef struct {
    struct MessageNode* head;
    struct MessageNode* tail;
    pthread_mutex_t lock;
} MessageQueue;

// Global message queue for callback-based processing
static MessageQueue g_message_queue = {NULL, NULL, PTHREAD_MUTEX_INITIALIZER};

// Add message to queue
void queue_message(BBMessage* msg) {
    pthread_mutex_lock(&g_message_queue.lock);

    struct MessageNode* node = malloc(sizeof(struct MessageNode));
    if (node) {
        node->msg = msg;
        node->next = NULL;

        if (!g_message_queue.head) {
            g_message_queue.head = g_message_queue.tail = node;
        } else {
            g_message_queue.tail->next = node;
            g_message_queue.tail = node;
        }
    }

    pthread_mutex_unlock(&g_message_queue.lock);
}

// Remove message from queue
BBMessage* dequeue_message(void) {
    pthread_mutex_lock(&g_message_queue.lock);

    BBMessage* msg = NULL;
    if (g_message_queue.head) {
        struct MessageNode* node = g_message_queue.head;
        g_message_queue.head = node->next;
        if (!g_message_queue.head) {
            g_message_queue.tail = NULL;
        }
        msg = node->msg;
        free(node);
    }

    pthread_mutex_unlock(&g_message_queue.lock);
    return msg;
}

BBResult process_pubsub_event(BBClient* client, const uint8_t* buffer, size_t len) {
    if (!client || !buffer || len < 1) return BB_ERROR;

    // Check if it's a pub/sub event
    if (buffer[0] != CMD_PUBSUB_EVENT) return BB_ERROR;

    // Pub/Sub event format:
    // [cmd:1=0xFF][seq:4][topicLen:2][topic:N][msgType:1][seq:8][ts:8][headersLen:4][headers:M][payloadLen:4][payload:P]

    size_t offset = 1;  // Skip command byte 0xFF
    offset += 4;  // Skip 4-byte sequence placeholder

    // Parse topic length (2 bytes, big-endian)
    if (offset + 2 > len) return BB_ERROR;
    uint16_t topic_len = (buffer[offset] << 8) | buffer[offset + 1];
    offset += 2;

    // Parse topic
    if (offset + topic_len > len) return BB_ERROR;
    char* topic_buf = malloc(topic_len + 1);
    if (!topic_buf) return BB_ERROR;
    memcpy(topic_buf, buffer + offset, topic_len);
    topic_buf[topic_len] = '\0';
    offset += topic_len;

    // Skip msgType (1), seq (8), ts (8)
    offset += 1 + 8 + 8;

    // Parse headers length (4 bytes, big-endian)
    if (offset + 4 > len) {
        free(topic_buf);
        return BB_ERROR;
    }
    uint32_t headers_len = ((uint32_t)buffer[offset] << 24) |
                           ((uint32_t)buffer[offset + 1] << 16) |
                           ((uint32_t)buffer[offset + 2] << 8) |
                           buffer[offset + 3];
    offset += 4;
    offset += headers_len;

    // Parse payload length (4 bytes, big-endian)
    if (offset + 4 > len) {
        free(topic_buf);
        return BB_ERROR;
    }
    uint32_t payload_len = ((uint32_t)buffer[offset] << 24) |
                           ((uint32_t)buffer[offset + 1] << 16) |
                           ((uint32_t)buffer[offset + 2] << 8) |
                           buffer[offset + 3];
    offset += 4;

    // Parse payload
    char* payload_buf = NULL;
    if (offset + payload_len <= len && payload_len > 0) {
        payload_buf = malloc(payload_len + 1);
        if (payload_buf) {
            memcpy(payload_buf, buffer + offset, payload_len);
            payload_buf[payload_len] = '\0';
        }
    }

    // Create message
    BBMessage* msg = calloc(1, sizeof(BBMessage));
    if (!msg) {
        free(topic_buf);
        if (payload_buf) free(payload_buf);
        return BB_ERROR;
    }
    msg->topic = topic_buf;
    msg->data = payload_buf ? payload_buf : strdup("");
    msg->timestamp = 0;

    // Call callback or queue message
    pthread_mutex_lock(&client->callback_lock);
    if (client->message_callback) {
        client->message_callback(msg, client->callback_userdata);
        bb_free_message(msg);
    } else {
        queue_message(msg);
    }
    pthread_mutex_unlock(&client->callback_lock);

    return BB_OK;
}

BBResult bb_subscribe(BBClient* client, const char* topic) {
    if (!client || !topic) return BB_ERROR;

    // Build request v1.1: [cmd:1][seq:4][flags:1][keyLen:2][key:0][valueLen:4][payload:N]
    // Payload format: [options:1][topicLen:2][topic:N][patternLen:2][pattern:0]
    size_t topic_len = strlen(topic);
    size_t payload_len = 1 + 2 + topic_len + 2;  // options + topicLen + topic + patternLen

    uint8_t buffer[BUFFER_SIZE];
    size_t offset = 0;
    uint32_t seq = client->next_seq++;

    // Command
    buffer[offset++] = CMD_SUBSCRIBE;

    // Sequence (4 bytes, big-endian)
    buffer[offset++] = (seq >> 24) & 0xFF;
    buffer[offset++] = (seq >> 16) & 0xFF;
    buffer[offset++] = (seq >> 8) & 0xFF;
    buffer[offset++] = seq & 0xFF;

    // Flags (1 byte) - no TTL
    buffer[offset++] = 0;

    // Key length (2 bytes) - empty key
    buffer[offset++] = 0;
    buffer[offset++] = 0;

    // Value length (4 bytes, big-endian)
    buffer[offset++] = (payload_len >> 24) & 0xFF;
    buffer[offset++] = (payload_len >> 16) & 0xFF;
    buffer[offset++] = (payload_len >> 8) & 0xFF;
    buffer[offset++] = payload_len & 0xFF;

    // Payload: options byte (0 = default)
    buffer[offset++] = 0;

    // Payload: topic length (2 bytes, big-endian)
    buffer[offset++] = (topic_len >> 8) & 0xFF;
    buffer[offset++] = topic_len & 0xFF;

    // Payload: topic
    memcpy(buffer + offset, topic, topic_len);
    offset += topic_len;

    // Payload: pattern length (2 bytes) - empty pattern
    buffer[offset++] = 0;
    buffer[offset++] = 0;

    // Send as binary frame
    if (ws_send_binary(client->ws, buffer, offset) < 0) {
        strncpy(client->last_error, ws_get_error(client->ws), sizeof(client->last_error) - 1);
        return BB_CONNECTION_ERROR;
    }

    // Receive response
    uint8_t* response_data = NULL;
    ssize_t response_len = ws_recv_binary(client->ws, &response_data, client->config.timeout_ms);
    if (response_len <= 0) {
        strncpy(client->last_error, "No response from server", sizeof(client->last_error) - 1);
        return BB_TIMEOUT;
    }

    // Parse response - format: [status:1][seq:4][valueLen:4][value:N]
    uint8_t status = response_data[0];

    if (status == STATUS_OK) {
        free(response_data);
        return BB_OK;
    } else {
        // Extract error message from response if available
        if (response_len > 9) {
            uint32_t value_len = ((uint32_t)response_data[5] << 24) |
                                 ((uint32_t)response_data[6] << 16) |
                                 ((uint32_t)response_data[7] << 8) |
                                 ((uint32_t)response_data[8]);
            if (value_len > 0 && (size_t)(9 + value_len) <= (size_t)response_len) {
                size_t copy_len = value_len < sizeof(client->last_error) - 1 ? value_len : sizeof(client->last_error) - 1;
                memcpy(client->last_error, response_data + 9, copy_len);
                client->last_error[copy_len] = '\0';
            }
        }
        free(response_data);
        if (status == STATUS_ERROR) {
            return BB_ERROR;
        } else {
            return BB_PROTOCOL_ERROR;
        }
    }
}

BBResult bb_unsubscribe(BBClient* client, const char* topic) {
    if (!client || !topic) return BB_ERROR;

    ProtocolRequest req = {
        .command = CMD_UNSUBSCRIBE,
        .seq = client->next_seq++,
        .key = topic,
        .value = ""
    };

    // Encode request
    uint8_t buffer[BUFFER_SIZE];
    ssize_t encoded_len = encode_request(buffer, &req, -1);
    if (encoded_len < 0) return BB_ERROR;

    if (ws_send_binary(client->ws, buffer, encoded_len) < 0) {
        strncpy(client->last_error, ws_get_error(client->ws), sizeof(client->last_error) - 1);
        return BB_CONNECTION_ERROR;
    }

    // Receive response
    uint8_t* response_data = NULL;
    ssize_t response_len = ws_recv_binary(client->ws, &response_data, client->config.timeout_ms);
    if (response_len <= 0) {
        strncpy(client->last_error, "No response from server", sizeof(client->last_error) - 1);
        return BB_TIMEOUT;
    }

    ProtocolResponse resp = {0};
    int decode_ret = decode_response(response_data, response_len, &resp);
    free(response_data);

    if (decode_ret < 0) return BB_PROTOCOL_ERROR;

    BBResult result = (resp.status == STATUS_OK) ? BB_OK : BB_ERROR;
    free(resp.value);
    return result;
}

BBResult bb_publish(BBClient* client, const char* topic, const char* data) {
    if (!client || !topic || !data) return BB_ERROR;

    // Encode publish payload
    uint8_t buffer[BUFFER_SIZE];
    ssize_t payload_len = encode_publish_request(buffer, client->next_seq++, topic, data);
    if (payload_len < 0) return BB_ERROR;

    // Create request with publish command
    ProtocolRequest req = {
        .command = CMD_PUBLISH,
        .seq = client->next_seq++,
        .key = "",
        .value = (char*)buffer  // Reusing buffer, but value is not used for publish
    };

    // Re-encode with proper command
    ssize_t encoded_len = encode_request(buffer, &req, -1);
    if (encoded_len < 0) return BB_ERROR;

    // Override the value field with actual publish data
    // This is a simplification - in practice, we'd have a special encoding for publish

    if (ws_send_binary(client->ws, buffer, encoded_len) < 0) {
        strncpy(client->last_error, ws_get_error(client->ws), sizeof(client->last_error) - 1);
        return BB_CONNECTION_ERROR;
    }

    return BB_OK;
}

// Process incoming messages (should be called periodically or in a thread)
void bb_process_messages(BBClient* client) {
    if (!client) return;

    uint8_t* response_data = NULL;
    ssize_t response_len = ws_recv_binary(client->ws, &response_data, 0);  // Non-blocking

    if (response_len > 0 && is_pubsub_event(response_data, response_len)) {
        // Parse pub/sub event
        // Format: [CMD_PUBSUB_EVENT:1][topic][0][data]
        size_t offset = 1;  // Skip command byte

        // Parse topic
        char* topic_start = (char*)(response_data + offset);
        char* topic_end = strchr(topic_start, '\0');
        if (topic_end) {
            offset += (topic_end - topic_start) + 1;

            // Parse data (rest of the message)
            size_t data_len = response_len - offset;
            char* data = malloc(data_len + 1);
            if (data) {
                memcpy(data, response_data + offset, data_len);
                data[data_len] = '\0';

                // Create message
                BBMessage* msg = calloc(1, sizeof(BBMessage));
                if (msg) {
                    msg->topic = strdup(topic_start);
                    msg->data = data;
                    msg->timestamp = 0;  // Could parse from message

                    // Call callback or queue message
                    pthread_mutex_lock(&client->callback_lock);
                    if (client->message_callback) {
                        client->message_callback(msg, client->callback_userdata);
                        bb_free_message(msg);
                    } else {
                        queue_message(msg);
                    }
                    pthread_mutex_unlock(&client->callback_lock);
                } else {
                    free(data);
                }
            }
        }
    }

    free(response_data);
}

BBMessage* bb_poll_message(BBClient* client) {
    (void)client;  // Client not used in simple implementation
    return dequeue_message();
}

BBMessage* bb_wait_message(BBClient* client, int timeout_ms) {
    if (!client) return NULL;

    // Poll for messages with timeout
    int elapsed = 0;
    int poll_interval = 100;  // Poll every 100ms

    while (elapsed < timeout_ms) {
        // Check for incoming messages
        uint8_t* response_data = NULL;
        ssize_t response_len = ws_recv_binary(client->ws, &response_data, poll_interval);

        if (response_len > 0 && is_pubsub_event(response_data, response_len)) {
            // Parse pub/sub event
            size_t offset = 1;  // Skip command byte

            char* topic_start = (char*)(response_data + offset);
            char* topic_end = strchr(topic_start, '\0');
            if (topic_end) {
                offset += (topic_end - topic_start) + 1;
                size_t data_len = response_len - offset;

                BBMessage* msg = calloc(1, sizeof(BBMessage));
                if (msg) {
                    msg->topic = strdup(topic_start);
                    msg->data = malloc(data_len + 1);
                    if (msg->data) {
                        memcpy(msg->data, response_data + offset, data_len);
                        msg->data[data_len] = '\0';
                        msg->timestamp = 0;
                        free(response_data);
                        return msg;
                    }
                    free(msg->topic);
                    free(msg);
                }
            }
        }

        free(response_data);
        elapsed += poll_interval;
    }

    return NULL;  // Timeout
}

void bb_free_message(BBMessage* msg) {
    if (!msg) return;
    free(msg->id);
    free(msg->topic);
    free(msg->data);
    free(msg);
}


// Helper to receive response, buffering any pub/sub events that arrive first.
// Callback is called after response is received with buffered events.
BBResult recv_response_and_buffer_events(BBClient* client, uint8_t** response_data,
                                                  ssize_t* response_len, BufferedEvent** events) {
    *events = NULL;
    *response_data = NULL;
    *response_len = 0;

    int max_attempts = 10;  // Prevent infinite loop

    while (max_attempts-- > 0) {
        *response_data = NULL;
        *response_len = ws_recv_binary(client->ws, response_data, client->config.timeout_ms);

        if (*response_len <= 0) {
            // Free buffered events
            while (*events) {
                BufferedEvent* ev = *events;
                *events = ev->next;
                free(ev->topic);
                if (ev->data) free(ev->data);
                free(ev);
            }
            strncpy(client->last_error, "No response from server", sizeof(client->last_error) - 1);
            return BB_TIMEOUT;
        }

        // Check if this is a pub/sub event (command byte 0xFF)
        if (is_pubsub_event(*response_data, *response_len)) {
            // Pub/Sub event format:
            // [cmd:1=0xFF][seq:4][topicLen:2][topic:N][msgType:1][seq:8][ts:8][headersLen:4][headers:M][payloadLen:4][payload:P]

            size_t offset = 1;  // Skip command byte 0xFF
            offset += 4;  // Skip 4-byte sequence placeholder

            // Parse topic length (2 bytes, big-endian)
            if (offset + 2 > (size_t)*response_len) {
                free(*response_data);
                continue;
            }
            uint16_t topic_len = ((*response_data)[offset] << 8) | (*response_data)[offset + 1];
            offset += 2;

            // Parse topic
            if (offset + topic_len > (size_t)*response_len) {
                free(*response_data);
                continue;
            }
            char* topic_buf = malloc(topic_len + 1);
            if (!topic_buf) {
                free(*response_data);
                continue;
            }
            memcpy(topic_buf, *response_data + offset, topic_len);
            topic_buf[topic_len] = '\0';
            offset += topic_len;

            // Skip msgType (1), seq (8), ts (8)
            offset += 1 + 8 + 8;

            // Parse headers length (4 bytes, big-endian)
            if (offset + 4 > (size_t)*response_len) {
                free(topic_buf);
                free(*response_data);
                continue;
            }
            uint32_t headers_len = ((uint32_t)(*response_data)[offset] << 24) |
                                   ((uint32_t)(*response_data)[offset + 1] << 16) |
                                   ((uint32_t)(*response_data)[offset + 2] << 8) |
                                   (*response_data)[offset + 3];
            offset += 4;
            offset += headers_len;

            // Parse payload length (4 bytes, big-endian)
            if (offset + 4 > (size_t)*response_len) {
                free(topic_buf);
                free(*response_data);
                continue;
            }
            uint32_t payload_len = ((uint32_t)(*response_data)[offset] << 24) |
                                   ((uint32_t)(*response_data)[offset + 1] << 16) |
                                   ((uint32_t)(*response_data)[offset + 2] << 8) |
                                   (*response_data)[offset + 3];
            offset += 4;

            // Parse payload
            char* payload_buf = NULL;
            if (offset + payload_len <= (size_t)*response_len && payload_len > 0) {
                payload_buf = malloc(payload_len + 1);
                if (payload_buf) {
                    memcpy(payload_buf, *response_data + offset, payload_len);
                    payload_buf[payload_len] = '\0';
                }
            }

            // Add event to buffered list
            BufferedEvent* ev = malloc(sizeof(BufferedEvent));
            if (ev) {
                ev->topic = topic_buf;
                ev->data = payload_buf;
                ev->next = NULL;
                if (!*events) {
                    *events = ev;
                } else {
                    // Find tail - simple approach, could be optimized
                    BufferedEvent* curr = *events;
                    while (curr->next) curr = curr->next;
                    curr->next = ev;
                }
            } else {
                free(topic_buf);
                if (payload_buf) free(payload_buf);
            }

            free(*response_data);
            *response_data = NULL;
            *response_len = 0;
            // Continue to read next message
            continue;
        }

        // This is a regular response
        return BB_OK;
    }

    // Too many attempts
    while (*events) {
        BufferedEvent* ev = *events;
        *events = ev->next;
        free(ev->topic);
        if (ev->data) free(ev->data);
        free(ev);
    }
    if (*response_data) free(*response_data);
    *response_data = NULL;
    strncpy(client->last_error, "Too many events before response", sizeof(client->last_error) - 1);
    return BB_TIMEOUT;
}

// Helper to process buffered events
void process_buffered_events(BBClient* client, BufferedEvent* events) {
    if (!events || !client->message_callback) return;

    pthread_mutex_lock(&client->callback_lock);
    BufferedEvent* ev = events;
    while (ev) {
        BBMessage msg;
        memset(&msg, 0, sizeof(msg));
        msg.topic = ev->topic;
        msg.data = ev->data ? ev->data : "";
        msg.timestamp = 0;

        client->message_callback(&msg, client->callback_userdata);
        ev = ev->next;
    }
    pthread_mutex_unlock(&client->callback_lock);
}

// Helper to free buffered events
void free_buffered_events(BufferedEvent* events) {
    while (events) {
        BufferedEvent* ev = events;
        events = ev->next;
        free(ev->topic);
        if (ev->data) free(ev->data);
        free(ev);
    }
}

BBResult bb_watch_key(BBClient* client, const char* pattern) {
    if (!client || !pattern) return BB_ERROR;

    // Get current barrel name
    const char* barrel_name = client->current_barrel ? client->current_barrel : "";
    size_t barrel_len = strlen(barrel_name);
    size_t pattern_len = strlen(pattern);

    // Watch request payload format: [barrelLen:2][barrel][patternLen:2][pattern][options:1]
    size_t payload_len = 2 + barrel_len + 2 + pattern_len + 1;

    uint8_t buffer[BUFFER_SIZE];
    size_t offset = 0;
    uint32_t seq = client->next_seq++;

    // Command
    buffer[offset++] = CMD_WATCH_KEY;

    // Sequence (4 bytes, big-endian)
    buffer[offset++] = (seq >> 24) & 0xFF;
    buffer[offset++] = (seq >> 16) & 0xFF;
    buffer[offset++] = (seq >> 8) & 0xFF;
    buffer[offset++] = seq & 0xFF;

    // Flags (1 byte)
    buffer[offset++] = 0;

    // Key length (2 bytes) - empty key for watch
    buffer[offset++] = 0;
    buffer[offset++] = 0;

    // Value length (4 bytes, big-endian)
    buffer[offset++] = (payload_len >> 24) & 0xFF;
    buffer[offset++] = (payload_len >> 16) & 0xFF;
    buffer[offset++] = (payload_len >> 8) & 0xFF;
    buffer[offset++] = payload_len & 0xFF;

    // Payload: barrel name length (2 bytes, big-endian)
    buffer[offset++] = (barrel_len >> 8) & 0xFF;
    buffer[offset++] = barrel_len & 0xFF;

    // Payload: barrel name
    memcpy(buffer + offset, barrel_name, barrel_len);
    offset += barrel_len;

    // Payload: pattern length (2 bytes, big-endian)
    buffer[offset++] = (pattern_len >> 8) & 0xFF;
    buffer[offset++] = pattern_len & 0xFF;

    // Payload: pattern
    memcpy(buffer + offset, pattern, pattern_len);
    offset += pattern_len;

    // Payload: options (1 = include values, 0 = keys only)
    buffer[offset++] = 0;  // Default: keys only

    // Send request
    if (ws_send_binary(client->ws, buffer, offset) < 0) {
        strncpy(client->last_error, ws_get_error(client->ws), sizeof(client->last_error) - 1);
        return BB_CONNECTION_ERROR;
    }

    // Receive response, skipping any pub/sub events
    uint8_t* response_data = NULL;
    ssize_t response_len = 0;
    int max_attempts = 10;

    while (max_attempts-- > 0) {
        response_data = NULL;
        response_len = ws_recv_binary(client->ws, &response_data, client->config.timeout_ms);
        if (response_len <= 0) {
            strncpy(client->last_error, "No response from server", sizeof(client->last_error) - 1);
            return BB_TIMEOUT;
        }
        // Skip pub/sub events
        if (is_pubsub_event(response_data, response_len)) {
            free(response_data);
            response_data = NULL;
            continue;
        }
        break;
    }

    if (max_attempts < 0 || !response_data) {
        if (response_data) free(response_data);
        strncpy(client->last_error, "Too many events before response", sizeof(client->last_error) - 1);
        return BB_TIMEOUT;
    }

    // Parse response
    uint8_t status = response_data[0];
    free(response_data);

    return (status == STATUS_OK) ? BB_OK : BB_ERROR;
}

BBResult bb_unwatch_key(BBClient* client, const char* pattern) {
    if (!client || !pattern) return BB_ERROR;

    // Get current barrel name
    const char* barrel_name = client->current_barrel ? client->current_barrel : "";
    size_t barrel_len = strlen(barrel_name);
    size_t pattern_len = strlen(pattern);

    // Unwatch request payload format: [barrelLen:2][barrel][patternLen:2][pattern][options:1]
    // Same as watch, server finds matching watches by this payload
    size_t payload_len = 2 + barrel_len + 2 + pattern_len + 1;

    uint8_t buffer[BUFFER_SIZE];
    size_t offset = 0;
    uint32_t seq = client->next_seq++;

    // Command
    buffer[offset++] = CMD_UNWATCH_KEY;

    // Sequence (4 bytes, big-endian)
    buffer[offset++] = (seq >> 24) & 0xFF;
    buffer[offset++] = (seq >> 16) & 0xFF;
    buffer[offset++] = (seq >> 8) & 0xFF;
    buffer[offset++] = seq & 0xFF;

    // Flags (1 byte)
    buffer[offset++] = 0;

    // Key length (2 bytes) - empty key for unwatch by pattern
    buffer[offset++] = 0;
    buffer[offset++] = 0;

    // Value length (4 bytes, big-endian)
    buffer[offset++] = (payload_len >> 24) & 0xFF;
    buffer[offset++] = (payload_len >> 16) & 0xFF;
    buffer[offset++] = (payload_len >> 8) & 0xFF;
    buffer[offset++] = payload_len & 0xFF;

    // Payload: barrel name length (2 bytes, big-endian)
    buffer[offset++] = (barrel_len >> 8) & 0xFF;
    buffer[offset++] = barrel_len & 0xFF;

    // Payload: barrel name
    memcpy(buffer + offset, barrel_name, barrel_len);
    offset += barrel_len;

    // Payload: pattern length (2 bytes, big-endian)
    buffer[offset++] = (pattern_len >> 8) & 0xFF;
    buffer[offset++] = pattern_len & 0xFF;

    // Payload: pattern
    memcpy(buffer + offset, pattern, pattern_len);
    offset += pattern_len;

    // Payload: options (1 = include values, 0 = keys only)
    buffer[offset++] = 0;  // Default: keys only

    // Send request
    if (ws_send_binary(client->ws, buffer, offset) < 0) {
        strncpy(client->last_error, ws_get_error(client->ws), sizeof(client->last_error) - 1);
        return BB_CONNECTION_ERROR;
    }

    // Receive response, skipping any pub/sub events
    uint8_t* response_data = NULL;
    ssize_t response_len = 0;
    int max_attempts = 10;

    while (max_attempts-- > 0) {
        response_data = NULL;
        response_len = ws_recv_binary(client->ws, &response_data, client->config.timeout_ms);
        if (response_len <= 0) {
            strncpy(client->last_error, "No response from server", sizeof(client->last_error) - 1);
            return BB_TIMEOUT;
        }
        // Skip pub/sub events
        if (is_pubsub_event(response_data, response_len)) {
            free(response_data);
            response_data = NULL;
            continue;
        }
        break;
    }

    if (max_attempts == 0 || !response_data) {
        if (response_data) free(response_data);
        strncpy(client->last_error, "Too many events before response", sizeof(client->last_error) - 1);
        return BB_TIMEOUT;
    }

    // Parse response
    uint8_t status = response_data[0];
    free(response_data);

    return (status == STATUS_OK) ? BB_OK : BB_ERROR;
}

BBResult bb_set_message_callback(BBClient* client, BBMessageCallback callback, void* userdata) {
    if (!client) return BB_ERROR;

    pthread_mutex_lock(&client->callback_lock);
    client->message_callback = callback;
    client->callback_userdata = userdata;
    pthread_mutex_unlock(&client->callback_lock);

    return BB_OK;
}

// Helper: Send request with key and optional binary value payload
static BBResult send_request_with_payload(BBClient* client, uint8_t command, const char* key,
                                        const uint8_t* value_payload, size_t value_len,
                                        uint8_t** response_data, ssize_t* response_len) {
    if (!client) return BB_ERROR;

    // Encode request
    uint8_t buffer[BUFFER_SIZE];
    size_t offset = 0;

    // Command (1 byte)
    buffer[offset++] = command;

    // Sequence number (4 bytes, big-endian)
    *(uint32_t*)(buffer + offset) = htobe32(client->next_seq++);
    offset += 4;

    // Flags (1 byte) - no TTL
    buffer[offset++] = 0;

    // Key length (2 bytes, big-endian) and key
    uint16_t key_len = key ? strlen(key) : 0;
    *(uint16_t*)(buffer + offset) = htobe16(key_len);
    offset += 2;
    if (key_len > 0) {
        memcpy(buffer + offset, key, key_len);
        offset += key_len;
    }

    // Value length (4 bytes, big-endian) and value payload
    *(uint32_t*)(buffer + offset) = htobe32(value_len);
    offset += 4;
    if (value_len > 0 && value_payload) {
        memcpy(buffer + offset, value_payload, value_len);
        offset += value_len;
    }

    // No TTL

    // Send request
    if (ws_send_binary(client->ws, buffer, offset) < 0) {
        strncpy(client->last_error, ws_get_error(client->ws), sizeof(client->last_error) - 1);
        return BB_CONNECTION_ERROR;
    }

    // Receive response
    *response_len = ws_recv_binary(client->ws, response_data, client->config.timeout_ms);
    if (*response_len <= 0) {
        strncpy(client->last_error, "No response from server", sizeof(client->last_error) - 1);
        return BB_TIMEOUT;
    }

    return BB_OK;
}

BBResult bb_list_subscribers(BBClient* client, const char* topic, char*** subscribers, size_t* count) {
    if (!client || !topic || !subscribers || !count) return BB_ERROR;

    // Send list subscribers command with topic as key
    uint8_t* response_data = NULL;
    ssize_t response_len = 0;
    BBResult result = send_request_with_payload(client, CMD_LIST_SUBSCRIBERS, topic, NULL, 0,
                                               &response_data, &response_len);
    if (result != BB_OK) {
        return result;
    }

    // Parse response
    ProtocolResponse resp = {0};
    if (decode_response(response_data, response_len, &resp) < 0) {
        free(response_data);
        return BB_PROTOCOL_ERROR;
    }

    // Response should be JSON array of subscriber IDs
    if (resp.status != STATUS_OK) {
        free(resp.value);
        free(response_data);
        return BB_ERROR;
    }

    // Parse JSON array (simplified parsing)
    // Format: ["id1","id2","id3"]
    char* json = resp.value;
    size_t sub_count = count_json_array_items(json);
    char** sub_array = malloc(sub_count * sizeof(char*));
    if (!sub_array) {
        free(resp.value);
        free(response_data);
        return BB_ERROR;
    }

    // Simple parsing: find quoted strings between brackets
    size_t idx = 0;
    const char* ptr = json;
    while (*ptr && idx < sub_count) {
        if (*ptr == '\"') {
            const char* start = ptr + 1;
            const char* end = strchr(start, '\"');
            if (end) {
                size_t len = end - start;
                sub_array[idx] = malloc(len + 1);
                if (sub_array[idx]) {
                    memcpy(sub_array[idx], start, len);
                    sub_array[idx][len] = '\0';
                    idx++;
                }
                ptr = end + 1;
            }
        }
        ptr++;
    }

    *subscribers = sub_array;
    *count = idx;

    free(resp.value);
    free(response_data);
    return BB_OK;
}

BBResult bb_list_topics(BBClient* client, char*** topics, size_t* count) {
    if (!client || !topics || !count) return BB_ERROR;

    // Send list topics command with empty key
    uint8_t* response_data = NULL;
    ssize_t response_len = 0;
    BBResult result = send_request_with_payload(client, CMD_LIST_TOPICS, "", NULL, 0,
                                               &response_data, &response_len);
    if (result != BB_OK) {
        return result;
    }

    // Parse response
    ProtocolResponse resp = {0};
    if (decode_response(response_data, response_len, &resp) < 0) {
        free(response_data);
        return BB_PROTOCOL_ERROR;
    }

    if (resp.status != STATUS_OK) {
        free(resp.value);
        free(response_data);
        return BB_ERROR;
    }

    // Parse JSON array of topics
    char* json = resp.value;
    size_t topic_count = count_json_array_items(json);
    char** topic_array = malloc(topic_count * sizeof(char*));
    if (!topic_array) {
        free(resp.value);
        free(response_data);
        return BB_ERROR;
    }

    size_t idx = 0;
    const char* ptr = json;
    while (*ptr && idx < topic_count) {
        if (*ptr == '\"') {
            const char* start = ptr + 1;
            const char* end = strchr(start, '\"');
            if (end) {
                size_t len = end - start;
                topic_array[idx] = malloc(len + 1);
                if (topic_array[idx]) {
                    memcpy(topic_array[idx], start, len);
                    topic_array[idx][len] = '\0';
                    idx++;
                }
                ptr = end + 1;
            }
        }
        ptr++;
    }

    *topics = topic_array;
    *count = idx;

    free(resp.value);
    free(response_data);
    return BB_OK;
}

BBResult bb_get_history(BBClient* client, const char* topic, int limit, int since_seq,
                       BBMessage*** messages, size_t* count) {
    if (!client || !topic || !messages || !count) return BB_ERROR;

    // Encode history request payload (includes topic, limit, since_seq)
    uint8_t payload[BUFFER_SIZE];
    ssize_t payload_len = encode_history_request(payload, topic, limit, since_seq);
    if (payload_len < 0) return BB_ERROR;

    // Send history command with empty key, payload as value
    uint8_t* response_data = NULL;
    ssize_t response_len = 0;
    BBResult result = send_request_with_payload(client, CMD_HISTORY, "", payload, payload_len,
                                               &response_data, &response_len);
    if (result != BB_OK) {
        return result;
    }

    // Parse response
    ProtocolResponse resp = {0};
    if (decode_response(response_data, response_len, &resp) < 0) {
        free(response_data);
        return BB_PROTOCOL_ERROR;
    }

    if (resp.status != STATUS_OK) {
        free(resp.value);
        free(response_data);
        return BB_ERROR;
    }

    // Parse JSON array of message objects
    char* json = resp.value;
    size_t msg_count = count_json_array_items(json);
    BBMessage** msg_array = malloc(msg_count * sizeof(BBMessage*));
    if (!msg_array) {
        free(resp.value);
        free(response_data);
        return BB_ERROR;
    }

    // Simplified parsing: extract fields from each JSON object
    size_t idx = 0;
    const char* ptr = json;
    while (*ptr && idx < msg_count) {
        if (*ptr == '{') {
            // Find matching '}'
            const char* obj_start = ptr;
            const char* obj_end = strchr(obj_start, '}');
            if (obj_end) {
                // Extract fields
                char* id = extract_json_field(obj_start, "id");
                char* topic_field = extract_json_field(obj_start, "topic");
                char* data = extract_json_field(obj_start, "data");
                char* timestamp_str = extract_json_field(obj_start, "timestamp");

                if (id && topic_field && data) {
                    msg_array[idx] = calloc(1, sizeof(BBMessage));
                    if (msg_array[idx]) {
                        msg_array[idx]->id = id;
                        msg_array[idx]->topic = topic_field;
                        msg_array[idx]->data = data;
                        msg_array[idx]->timestamp = timestamp_str ? atoll(timestamp_str) : 0;
                        if (timestamp_str) free(timestamp_str);
                        idx++;
                    } else {
                        free(id);
                        free(topic_field);
                        free(data);
                        if (timestamp_str) free(timestamp_str);
                    }
                } else {
                    if (id) free(id);
                    if (topic_field) free(topic_field);
                    if (data) free(data);
                    if (timestamp_str) free(timestamp_str);
                }
                ptr = obj_end + 1;
            }
        }
        ptr++;
    }

    *messages = msg_array;
    *count = idx;

    free(resp.value);
    free(response_data);
    return BB_OK;
}

BBResult bb_get_presence(BBClient* client, const char* topic, char** presence_json) {
    if (!client || !topic || !presence_json) return BB_ERROR;

    // Encode presence request payload (operation 0 = get presence)
    uint8_t payload[BUFFER_SIZE];
    ssize_t payload_len = encode_presence_request(payload, 0);
    if (payload_len < 0) return BB_ERROR;

    // Send presence command with topic as key, operation as value payload
    uint8_t* response_data = NULL;
    ssize_t response_len = 0;
    BBResult result = send_request_with_payload(client, CMD_PRESENCE, topic, payload, payload_len,
                                               &response_data, &response_len);
    if (result != BB_OK) {
        return result;
    }

    // Parse response
    ProtocolResponse resp = {0};
    if (decode_response(response_data, response_len, &resp) < 0) {
        free(response_data);
        return BB_PROTOCOL_ERROR;
    }

    if (resp.status != STATUS_OK) {
        free(resp.value);
        free(response_data);
        return BB_ERROR;
    }

    // Return JSON string (caller must free)
    *presence_json = strdup(resp.value);

    free(resp.value);
    free(response_data);
    return BB_OK;
}
