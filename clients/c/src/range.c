#define _GNU_SOURCE

#include "../include/bitbarrel.h"
#include "bitbarrel_internal.h"
#include "protocol.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>

#define BUFFER_SIZE (64 * 1024)

extern ssize_t encode_range_request(uint8_t* buffer, const char* start_key,
                             const char* end_key, size_t limit, const char* cursor);
extern ssize_t encode_prefix_request(uint8_t* buffer, const char* prefix,
                              size_t limit, const char* cursor);

// Parse range response (matches Nim protocol)
// Format: [count:4][items...][hasMore:1][nextCursorLen:2][nextCursor:N]
// Each item: [keyLen:2][key:N][valLen:4][value:M]
static int parse_range_response(const uint8_t* data, size_t len, BBRangeResult* result) {
    if (len < 4) return -1;

    size_t offset = 0;

    // Count (4 bytes, big-endian)
    result->count = be32toh(*(uint32_t*)(data + offset));
    offset += 4;

    // Initialize
    result->keys = NULL;
    result->values = NULL;
    result->next_cursor = NULL;
    result->has_more = false;

    // Parse items
    if (result->count > 0) {
        result->keys = calloc(result->count, sizeof(char*));
        result->values = calloc(result->count, sizeof(char*));

        if (!result->keys || !result->values) {
            free(result->keys);
            free(result->values);
            result->keys = NULL;
            result->values = NULL;
            return -1;
        }

        // Parse key-value pairs
        for (size_t i = 0; i < result->count && offset < len; i++) {
            // Key length (2 bytes, big-endian)
            if (offset + 2 > len) break;
            uint16_t key_len = be16toh(*(uint16_t*)(data + offset));
            offset += 2;

            // Key
            if (offset + key_len > len) break;
            result->keys[i] = malloc(key_len + 1);
            if (!result->keys[i]) break;
            memcpy(result->keys[i], data + offset, key_len);
            result->keys[i][key_len] = '\0';
            offset += key_len;

            // Value length (4 bytes, big-endian)
            if (offset + 4 > len) break;
            uint32_t val_len = be32toh(*(uint32_t*)(data + offset));
            offset += 4;

            // Value
            if (offset + val_len > len) break;
            result->values[i] = malloc(val_len + 1);
            if (!result->values[i]) break;
            memcpy(result->values[i], data + offset, val_len);
            result->values[i][val_len] = '\0';
            offset += val_len;
        }
    }

    // Parse hasMore (1 byte)
    if (offset < len) {
        result->has_more = data[offset++] != 0;
    }

    // Parse nextCursor length (2 bytes, big-endian)
    if (offset + 2 <= len) {
        uint16_t cursor_len = be16toh(*(uint16_t*)(data + offset));
        offset += 2;

        if (cursor_len > 0 && offset + cursor_len <= len) {
            result->next_cursor = malloc(cursor_len + 1);
            if (result->next_cursor) {
                memcpy(result->next_cursor, data + offset, cursor_len);
                result->next_cursor[cursor_len] = '\0';
            }
        }
    }

    return 0;
}

// Helper to decode response with binary value (for range queries)
static int decode_range_response_binary(const uint8_t* buffer, size_t len,
                                        ProtocolResponse* resp, uint8_t** value_out, size_t* value_len) {
    if (len < 9) return -1;  // Minimum size

    size_t offset = 0;

    // Status (1 byte)
    resp->status = buffer[offset++];

    // Sequence number (4 bytes, big-endian)
    resp->seq = be32toh(*(uint32_t*)(buffer + offset));
    offset += 4;

    // Value length (4 bytes, big-endian)
    uint32_t val_len = be32toh(*(uint32_t*)(buffer + offset));
    offset += 4;

    // Check if we have enough data
    if (len < offset + val_len) return -1;

    // Return value as binary
    *value_len = val_len;
    if (val_len > 0) {
        *value_out = malloc(val_len);
        if (!*value_out) return -1;
        memcpy(*value_out, buffer + offset, val_len);
    } else {
        *value_out = NULL;
    }

    resp->value = NULL;
    return 0;
}

BBResult bb_items_in_range(BBClient* client, const char* start_key, const char* end_key,
                          size_t limit, const char* cursor, BBRangeResult** result) {
    if (!client || !result) return BB_ERROR;

    *result = NULL;

    // Encode range request payload
    uint8_t payload[BUFFER_SIZE];
    ssize_t payload_len = encode_range_request(payload, start_key, end_key, limit, cursor);
    if (payload_len < 0) return BB_ERROR;

    // Build complete request: [cmd:1][seq:4][flags:1][keyLen:2][valLen:4][value:N]
    uint8_t request[BUFFER_SIZE];
    size_t offset = 0;

    request[offset++] = CMD_RANGE_QUERY;

    uint32_t seq = client->next_seq++;
    *(uint32_t*)(request + offset) = htobe32(seq);
    offset += 4;

    request[offset++] = 0;  // flags

    *(uint16_t*)(request + offset) = htobe16(0);  // keyLen = 0
    offset += 2;

    *(uint32_t*)(request + offset) = htobe32((uint32_t)payload_len);
    offset += 4;

    memcpy(request + offset, payload, payload_len);
    offset += payload_len;

    // Send request
    pthread_mutex_lock(&client->request_lock);

    if (ws_send_binary(client->ws, request, offset) < 0) {
        strncpy(client->last_error, ws_get_error(client->ws), sizeof(client->last_error) - 1);
        pthread_mutex_unlock(&client->request_lock);
        return BB_CONNECTION_ERROR;
    }

    // Receive response
    uint8_t* response_data = NULL;
    ssize_t response_len = ws_recv_binary(client->ws, &response_data, client->config.timeout_ms);
    if (response_len <= 0) {
        strncpy(client->last_error, "No response from server", sizeof(client->last_error) - 1);
        pthread_mutex_unlock(&client->request_lock);
        return BB_TIMEOUT;
    }

    pthread_mutex_unlock(&client->request_lock);

    // Parse response with binary value
    ProtocolResponse resp = {0};
    uint8_t* value_data = NULL;
    size_t value_len = 0;
    int decode_ret = decode_range_response_binary(response_data, response_len, &resp, &value_data, &value_len);
    free(response_data);

    if (decode_ret < 0) return BB_PROTOCOL_ERROR;

    BBResult result_code = BB_ERROR;
    if (resp.status == STATUS_OK) {
        *result = calloc(1, sizeof(BBRangeResult));
        if (*result) {
            if (value_data && value_len > 0) {
                if (parse_range_response(value_data, value_len, *result) == 0) {
                    result_code = BB_OK;
                } else {
                    free(*result);
                    *result = NULL;
                }
            } else {
                // Empty result
                (*result)->count = 0;
                (*result)->keys = NULL;
                (*result)->values = NULL;
                (*result)->next_cursor = NULL;
                (*result)->has_more = false;
                result_code = BB_OK;
            }
        }
    } else if (resp.status == STATUS_NO_BARREL) {
        result_code = BB_NO_BARREL;
    } else {
        if (value_data) {
            // Value might contain error message
            strncpy(client->last_error, (char*)value_data, sizeof(client->last_error) - 1);
        }
        result_code = BB_ERROR;
    }

    free(value_data);
    return result_code;
}

BBResult bb_items_with_prefix(BBClient* client, const char* prefix,
                             size_t limit, const char* cursor, BBRangeResult** result) {
    if (!client || !result) return BB_ERROR;

    *result = NULL;

    // Encode prefix request payload
    uint8_t payload[BUFFER_SIZE];
    ssize_t payload_len = encode_prefix_request(payload, prefix, limit, cursor);
    if (payload_len < 0) return BB_ERROR;

    // Build complete request: [cmd:1][seq:4][flags:1][keyLen:2][valLen:4][value:N]
    uint8_t request[BUFFER_SIZE];
    size_t offset = 0;

    request[offset++] = CMD_PREFIX_QUERY;

    uint32_t seq = client->next_seq++;
    *(uint32_t*)(request + offset) = htobe32(seq);
    offset += 4;

    request[offset++] = 0;  // flags

    *(uint16_t*)(request + offset) = htobe16(0);  // keyLen = 0
    offset += 2;

    *(uint32_t*)(request + offset) = htobe32((uint32_t)payload_len);
    offset += 4;

    memcpy(request + offset, payload, payload_len);
    offset += payload_len;

    // Send request
    pthread_mutex_lock(&client->request_lock);

    if (ws_send_binary(client->ws, request, offset) < 0) {
        strncpy(client->last_error, ws_get_error(client->ws), sizeof(client->last_error) - 1);
        pthread_mutex_unlock(&client->request_lock);
        return BB_CONNECTION_ERROR;
    }

    // Receive response
    uint8_t* response_data = NULL;
    ssize_t response_len = ws_recv_binary(client->ws, &response_data, client->config.timeout_ms);
    if (response_len <= 0) {
        strncpy(client->last_error, "No response from server", sizeof(client->last_error) - 1);
        pthread_mutex_unlock(&client->request_lock);
        return BB_TIMEOUT;
    }

    pthread_mutex_unlock(&client->request_lock);

    // Parse response with binary value
    ProtocolResponse resp = {0};
    uint8_t* value_data = NULL;
    size_t value_len = 0;
    int decode_ret = decode_range_response_binary(response_data, response_len, &resp, &value_data, &value_len);
    free(response_data);

    if (decode_ret < 0) return BB_PROTOCOL_ERROR;

    BBResult result_code = BB_ERROR;
    if (resp.status == STATUS_OK) {
        *result = calloc(1, sizeof(BBRangeResult));
        if (*result) {
            if (value_data && value_len > 0) {
                if (parse_range_response(value_data, value_len, *result) == 0) {
                    result_code = BB_OK;
                } else {
                    free(*result);
                    *result = NULL;
                }
            } else {
                // Empty result
                (*result)->count = 0;
                (*result)->keys = NULL;
                (*result)->values = NULL;
                (*result)->next_cursor = NULL;
                (*result)->has_more = false;
                result_code = BB_OK;
            }
        }
    } else if (resp.status == STATUS_NO_BARREL) {
        result_code = BB_NO_BARREL;
    } else {
        if (value_data) {
            strncpy(client->last_error, (char*)value_data, sizeof(client->last_error) - 1);
        }
        result_code = BB_ERROR;
    }

    free(value_data);
    return result_code;
}

void bb_free_range_result(BBRangeResult* result) {
    if (!result) return;

    free(result->next_cursor);

    if (result->keys) {
        for (size_t i = 0; i < result->count; i++) {
            free(result->keys[i]);
        }
        free(result->keys);
    }

    if (result->values) {
        for (size_t i = 0; i < result->count; i++) {
            free(result->values[i]);
        }
        free(result->values);
    }

    free(result);
}
