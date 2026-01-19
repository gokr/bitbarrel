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

// Parse range response
// Format: [count:4][hasMore:1][nextCursor][0][key1][0][value1][0][key2][0][value2][0]...
static int parse_range_response(const uint8_t* data, size_t len, BBRangeResult* result) {
    if (len < 5) return -1;

    size_t offset = 0;

    // Count (4 bytes, big-endian)
    result->count = be32toh(*(uint32_t*)(data + offset));
    offset += 4;

    // hasMore (1 byte)
    result->has_more = data[offset++];

    // Parse items
    if (result->count > 0) {
        result->keys = calloc(result->count, sizeof(char*));
        result->values = calloc(result->count, sizeof(char*));

        if (!result->keys || !result->values) {
            free(result->keys);
            free(result->values);
            return -1;
        }

        // Parse nextCursor
        char* cursor_start = (char*)(data + offset);
        char* cursor_end = strchr(cursor_start, '\0');
        if (cursor_end) {
            result->next_cursor = strdup(cursor_start);
            offset += (cursor_end - cursor_start) + 1;
        } else {
            result->next_cursor = NULL;
        }

        // Parse key-value pairs
        for (size_t i = 0; i < result->count; i++) {
            char* key_start = (char*)(data + offset);
            char* key_end = strchr(key_start, '\0');
            if (!key_end) break;

            result->keys[i] = strdup(key_start);
            offset += (key_end - key_start) + 1;

            char* value_start = (char*)(data + offset);
            char* value_end = strchr(value_start, '\0');
            if (!value_end) {
                free(result->keys[i]);
                break;
            }

            result->values[i] = strdup(value_start);
            offset += (value_end - value_start) + 1;
        }
    } else {
        result->keys = NULL;
        result->values = NULL;
        result->next_cursor = NULL;
    }

    return 0;
}

BBResult bb_items_in_range(BBClient* client, const char* start_key, const char* end_key,
                          size_t limit, const char* cursor, BBRangeResult** result) {
    if (!client || !result) return BB_ERROR;

    *result = NULL;

    // Encode range request
    uint8_t buffer[BUFFER_SIZE];
    ssize_t payload_len = encode_range_request(buffer, start_key, end_key, limit, cursor);
    if (payload_len < 0) return BB_ERROR;

    // Create protocol request
    ProtocolRequest req = {
        .command = CMD_RANGE_QUERY,
        .seq = client->next_seq++,
        .key = "",
        .value = (char*)buffer  // Payload is in buffer
    };

    // Re-encode with command
    ssize_t encoded_len = encode_request(buffer, &req, -1);
    if (encoded_len < 0) return BB_ERROR;

    // Send request
    pthread_mutex_lock(&client->request_lock);

    if (ws_send_binary(client->ws, buffer, encoded_len) < 0) {
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

    // Parse response
    ProtocolResponse resp;
    int decode_ret = decode_response(response_data, response_len, &resp);
    free(response_data);

    if (decode_ret < 0) return BB_PROTOCOL_ERROR;

    BBResult result_code = BB_ERROR;
    if (resp.status == STATUS_OK) {
        *result = calloc(1, sizeof(BBRangeResult));
        if (*result) {
            if (parse_range_response((uint8_t*)resp.value, strlen(resp.value), *result) == 0) {
                result_code = BB_OK;
            } else {
                free(*result);
                *result = NULL;
            }
        }
    } else if (resp.status == STATUS_NO_BARREL) {
        result_code = BB_NO_BARREL;
    } else {
        result_code = BB_ERROR;
    }

    free(resp.value);
    return result_code;
}

BBResult bb_items_with_prefix(BBClient* client, const char* prefix,
                             size_t limit, const char* cursor, BBRangeResult** result) {
    if (!client || !result) return BB_ERROR;

    *result = NULL;

    // Encode prefix request
    uint8_t buffer[BUFFER_SIZE];
    ssize_t payload_len = encode_prefix_request(buffer, prefix, limit, cursor);
    if (payload_len < 0) return BB_ERROR;

    // Create protocol request
    ProtocolRequest req = {
        .command = CMD_PREFIX_QUERY,
        .seq = client->next_seq++,
        .key = "",
        .value = (char*)buffer
    };

    // Re-encode with command
    ssize_t encoded_len = encode_request(buffer, &req, -1);
    if (encoded_len < 0) return BB_ERROR;

    // Send request
    pthread_mutex_lock(&client->request_lock);

    if (ws_send_binary(client->ws, buffer, encoded_len) < 0) {
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

    // Parse response
    ProtocolResponse resp;
    int decode_ret = decode_response(response_data, response_len, &resp);
    free(response_data);

    if (decode_ret < 0) return BB_PROTOCOL_ERROR;

    BBResult result_code = BB_ERROR;
    if (resp.status == STATUS_OK) {
        *result = calloc(1, sizeof(BBRangeResult));
        if (*result) {
            if (parse_range_response((uint8_t*)resp.value, strlen(resp.value), *result) == 0) {
                result_code = BB_OK;
            } else {
                free(*result);
                *result = NULL;
            }
        }
    } else if (resp.status == STATUS_NO_BARREL) {
        result_code = BB_NO_BARREL;
    } else {
        result_code = BB_ERROR;
    }

    free(resp.value);
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
