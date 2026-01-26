#define _GNU_SOURCE  // For strdup and strtok_r

#include "../include/bitbarrel.h"
#include "bitbarrel_internal.h"
#include "protocol.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

#define BUFFER_SIZE (64 * 1024)  // 64KB buffer

static BBResult translate_error(int err) {
    switch (err) {
        case 0: return BB_OK;
        case -1: return BB_ERROR;
        case STATUS_NOT_FOUND: return BB_NOT_FOUND;
        case STATUS_NO_BARREL: return BB_NO_BARREL;
        case STATUS_BARREL_EXISTS: return BB_BARREL_EXISTS;
        case STATUS_INVALID: return BB_INVALID_REQUEST;
        default: return BB_ERROR;
    }
}

static void free_server_info(ServerInfo* info) {
    if (!info) return;

    free(info->server_id);
    info->server_id = NULL;

    if (info->plugins) {
        for (size_t i = 0; i < info->plugin_count; i++) {
            free(info->plugins[i]);
        }
        free(info->plugins);
        info->plugins = NULL;
    }

    info->plugin_count = 0;
}

static BBResult parse_handshake(const uint8_t* data, size_t len, ServerInfo* info) {
    if (!data || !info) return BB_ERROR;

    // Clear existing info
    free_server_info(info);

    size_t offset = 0;

    // Parse version
    if (len < 2) return BB_ERROR;
    info->version_major = data[offset++];
    info->version_minor = data[offset++];

    // Parse server ID length (2 bytes, big-endian)
    if (len < offset + 2) return BB_ERROR;
    uint16_t server_id_len = (data[offset] << 8) | data[offset + 1];
    offset += 2;

    // Parse server ID
    if (len < offset + server_id_len) return BB_ERROR;
    info->server_id = malloc(server_id_len + 1);
    if (!info->server_id) return BB_ERROR;
    memcpy(info->server_id, data + offset, server_id_len);
    info->server_id[server_id_len] = '\0';
    offset += server_id_len;

    // Parse plugin count
    if (len < offset + 1) return BB_ERROR;
    info->plugin_count = data[offset++];

    // Parse plugins
    if (info->plugin_count > 0) {
        info->plugins = calloc(info->plugin_count, sizeof(char*));
        if (!info->plugins) {
            free(info->server_id);
            info->server_id = NULL;
            return BB_ERROR;
        }

        for (size_t i = 0; i < info->plugin_count; i++) {
            // Parse plugin name length (2 bytes, big-endian)
            if (len < offset + 2) {
                free_server_info(info);
                return BB_ERROR;
            }
            uint16_t plugin_name_len = (data[offset] << 8) | data[offset + 1];
            offset += 2;

            // Parse plugin name
            if (len < offset + plugin_name_len) {
                free_server_info(info);
                return BB_ERROR;
            }
            info->plugins[i] = malloc(plugin_name_len + 1);
            if (!info->plugins[i]) {
                free_server_info(info);
                return BB_ERROR;
            }
            memcpy(info->plugins[i], data + offset, plugin_name_len);
            info->plugins[i][plugin_name_len] = '\0';
            offset += plugin_name_len;
        }
    }

    return BB_OK;
}

BBResult bb_init(void) {
    // Initialize SSL if needed
    // For now, return OK
    return BB_OK;
}

void bb_cleanup(void) {
    // Cleanup global state if any
}

BBConfig bb_config_default(void) {
    BBConfig config = {
        .url = "ws://localhost:7687",
        .timeout_ms = 5000,
        .max_retries = 3,
        .enable_auto_reconnect = true
    };
    return config;
}

BBClient* bb_client_create(const BBConfig* config) {
    BBClient* client = calloc(1, sizeof(BBClient));
    if (!client) return NULL;

    // Copy config
    client->config = *config;

    // Initialize WebSocket
    WSConfig ws_config = ws_config_default();
    ws_config.url = config->url;
    ws_config.timeout_ms = config->timeout_ms;

    client->ws = ws_create(&ws_config);
    if (!client->ws) {
        free(client);
        return NULL;
    }

    // Initialize locks
    pthread_mutex_init(&client->callback_lock, NULL);
    pthread_mutex_init(&client->error_lock, NULL);
    pthread_mutex_init(&client->request_lock, NULL);

    // Initialize sequence counter
    client->next_seq = 1;

    return client;
}

void bb_client_destroy(BBClient* client) {
    if (!client) return;

    // Disconnect if needed
    if (bb_is_connected(client)) {
        bb_disconnect(client);
    }

    // Cleanup
    free(client->current_barrel);
    free_server_info(&client->server_info);
    ws_destroy(client->ws);
    pthread_mutex_destroy(&client->callback_lock);
    pthread_mutex_destroy(&client->error_lock);
    pthread_mutex_destroy(&client->request_lock);
    free(client);
}

BBResult bb_connect(BBClient* client) {
    if (!client) return BB_ERROR;

    if (ws_is_connected(client->ws)) {
        return BB_OK;
    }

    int ret = ws_connect(client->ws);
    if (ret < 0) {
        strncpy(client->last_error, ws_get_error(client->ws), sizeof(client->last_error) - 1);
        return BB_CONNECTION_ERROR;
    }

    // Receive binary handshake
    uint8_t* handshake_data = NULL;
    ssize_t handshake_len = ws_recv_binary(client->ws, &handshake_data, client->config.timeout_ms);
    if (handshake_len <= 0) {
        strncpy(client->last_error, "Failed to receive server handshake", sizeof(client->last_error) - 1);
        if (handshake_data) free(handshake_data);
        ws_disconnect(client->ws);
        return BB_CONNECTION_ERROR;
    }

    // Parse handshake
    if (parse_handshake(handshake_data, handshake_len, &client->server_info) != BB_OK) {
        strncpy(client->last_error, "Failed to parse server handshake", sizeof(client->last_error) - 1);
        free(handshake_data);
        ws_disconnect(client->ws);
        return BB_PROTOCOL_ERROR;
    }

    free(handshake_data);
    client->handshake_received = true;

    // Verify connection with PING
    ProtocolRequest req = {
        .command = CMD_PING,
        .seq = client->next_seq++,
        .key = "",
        .value = ""
    };

    uint8_t buffer[BUFFER_SIZE];
    ssize_t encoded_len = encode_request(buffer, &req, -1);
    if (encoded_len < 0) {
        strncpy(client->last_error, "Failed to encode request", sizeof(client->last_error) - 1);
        return BB_PROTOCOL_ERROR;
    }

    if (ws_send_binary(client->ws, buffer, encoded_len) < 0) {
        strncpy(client->last_error, ws_get_error(client->ws), sizeof(client->last_error) - 1);
        return BB_CONNECTION_ERROR;
    }

    // Receive response
    uint8_t* response_data = NULL;
    ssize_t response_len = ws_recv_binary(client->ws, &response_data, client->config.timeout_ms);
    if (response_len <= 0) {
        strncpy(client->last_error, "No response from server", sizeof(client->last_error) - 1);
        if (response_data) free(response_data);
        return BB_CONNECTION_ERROR;
    }

    ProtocolResponse resp = {0};
    if (decode_response(response_data, response_len, &resp) < 0) {
        strncpy(client->last_error, "Failed to decode response", sizeof(client->last_error) - 1);
        free(response_data);
        free(resp.value);
        return BB_PROTOCOL_ERROR;
    }

    free(response_data);

    if (resp.status != STATUS_OK || strcmp(resp.value, "pong") != 0) {
        strncpy(client->last_error, "Invalid handshake response", sizeof(client->last_error) - 1);
        free(resp.value);
        return BB_PROTOCOL_ERROR;
    }

    free(resp.value);
    return BB_OK;
}

BBResult bb_disconnect(BBClient* client) {
    if (!client) return BB_ERROR;

    ws_disconnect(client->ws);
    free(client->current_barrel);
    client->current_barrel = NULL;

    return BB_OK;
}

bool bb_is_connected(const BBClient* client) {
    return client && ws_is_connected(client->ws);
}

static BBResult send_request(BBClient* client, const ProtocolRequest* req,
                             ProtocolResponse* resp, int timeout_ms) {
    pthread_mutex_lock(&client->request_lock);

    uint8_t buffer[BUFFER_SIZE];
    ssize_t encoded_len = encode_request(buffer, req, -1);  // TTL handled separately if needed
    if (encoded_len < 0) {
        strncpy(client->last_error, "Failed to encode request", sizeof(client->last_error) - 1);
        pthread_mutex_unlock(&client->request_lock);
        return BB_PROTOCOL_ERROR;
    }

    if (ws_send_binary(client->ws, buffer, encoded_len) < 0) {
        strncpy(client->last_error, ws_get_error(client->ws), sizeof(client->last_error) - 1);
        pthread_mutex_unlock(&client->request_lock);
        return BB_CONNECTION_ERROR;
    }

    // Skip pub/sub events that arrive before the response
    uint8_t* response_data = NULL;
    ssize_t response_len = 0;
    int max_attempts = 10;  // Prevent infinite loop

    while (max_attempts-- > 0) {
        response_data = NULL;
        response_len = ws_recv_binary(client->ws, &response_data, timeout_ms);
        if (response_len <= 0) {
            // Check if connection was closed
            if (!ws_is_connected(client->ws)) {
                const char* ws_error = ws_get_error(client->ws);
                snprintf(client->last_error, sizeof(client->last_error), "Connection closed: %s", ws_error);
            } else {
                const char* ws_error = ws_get_error(client->ws);
                snprintf(client->last_error, sizeof(client->last_error), "Receive error: %s", ws_error);
            }
            pthread_mutex_unlock(&client->request_lock);
            return BB_CONNECTION_ERROR;
        }

        // Skip pub/sub events (command byte 0xFF)
        if (is_pubsub_event(response_data, response_len)) {
            free(response_data);
            response_data = NULL;
            continue;
        }

        // This is a regular response
        break;
    }

    if (max_attempts < 0) {
        if (response_data) free(response_data);
        strncpy(client->last_error, "Too many events before response", sizeof(client->last_error) - 1);
        pthread_mutex_unlock(&client->request_lock);
        return BB_TIMEOUT;
    }

    int decode_ret = decode_response(response_data, response_len, resp);

    if (decode_ret < 0) {
        char err_msg[256];
        snprintf(err_msg, sizeof(err_msg), "Failed to decode response (len=%zd, first bytes: %02x %02x %02x %02x)",
                 response_len,
                 response_len > 0 ? response_data[0] : 0,
                 response_len > 1 ? response_data[1] : 0,
                 response_len > 2 ? response_data[2] : 0,
                 response_len > 3 ? response_data[3] : 0);
        strncpy(client->last_error, err_msg, sizeof(client->last_error) - 1);
        free(response_data);
        pthread_mutex_unlock(&client->request_lock);
        return BB_PROTOCOL_ERROR;
    }

    free(response_data);

    pthread_mutex_unlock(&client->request_lock);
    return BB_OK;
}

BBResult bb_create_barrel(BBClient* client, const char* name, BBMode mode) {
    if (!client || !name) return BB_ERROR;

    // Server expects JSON config or empty string for default
    // BM_HASH is default, so send empty string
    // BM_CRITBIT requires explicit JSON config
    ProtocolRequest req = {
        .command = CMD_CREATE_BARREL,
        .seq = client->next_seq++,
        .key = name,
        .value = (mode == BM_CRITBIT) ? "{\"mode\": \"critbit\"}" : ""
    };

    ProtocolResponse resp;
    memset(&resp, 0, sizeof(resp));
    BBResult result = send_request(client, &req, &resp, client->config.timeout_ms);

    if (result == BB_OK) {
        if (resp.status == STATUS_OK) {
            result = BB_OK;
        } else if (resp.status == STATUS_BARREL_EXISTS) {
            result = BB_BARREL_EXISTS;
        } else {
            // Store server error message
            if (resp.value && resp.value[0]) {
                strncpy(client->last_error, resp.value, sizeof(client->last_error) - 1);
            }
            result = translate_error(resp.status);
        }
    }

    free(resp.value);
    return result;
}

BBResult bb_open_barrel(BBClient* client, const char* name) {
    if (!client || !name) return BB_ERROR;

    ProtocolRequest req = {
        .command = CMD_OPEN_BARREL,
        .seq = client->next_seq++,
        .key = name,
        .value = ""
    };

    ProtocolResponse resp = {0};
    BBResult result = send_request(client, &req, &resp, client->config.timeout_ms);

    if (result == BB_OK) {
        if (resp.status == STATUS_OK) {
            result = BB_OK;
        } else if (resp.status == STATUS_BARREL_NOT_FOUND) {
            result = BB_NO_BARREL;
        } else {
            result = translate_error(resp.status);
        }
    }

    free(resp.value);
    return result;
}

BBResult bb_use_barrel(BBClient* client, const char* name) {
    if (!client || !name) return BB_ERROR;

    ProtocolRequest req = {
        .command = CMD_USE_BARREL,
        .seq = client->next_seq++,
        .key = name,
        .value = ""
    };

    ProtocolResponse resp = {0};
    BBResult result = send_request(client, &req, &resp, client->config.timeout_ms);

    if (result == BB_OK) {
        if (resp.status == STATUS_OK) {
            // Update current barrel
            free(client->current_barrel);
            client->current_barrel = strdup(name);
            result = BB_OK;
        } else if (resp.status == STATUS_BARREL_NOT_FOUND) {
            result = BB_NO_BARREL;
        } else {
            result = translate_error(resp.status);
        }
    }

    free(resp.value);
    return result;
}

BBResult bb_close_barrel(BBClient* client) {
    if (!client) return BB_ERROR;

    ProtocolRequest req = {
        .command = CMD_CLOSE_BARREL,
        .seq = client->next_seq++,
        .key = "",
        .value = ""
    };

    ProtocolResponse resp = {0};
    BBResult result = send_request(client, &req, &resp, client->config.timeout_ms);

    if (result == BB_OK) {
        if (resp.status == STATUS_OK) {
            free(client->current_barrel);
            client->current_barrel = NULL;
            result = BB_OK;
        } else {
            result = translate_error(resp.status);
        }
    }

    free(resp.value);
    return result;
}

BBResult bb_list_barrels(BBClient* client, char*** barrels, size_t* count) {
    if (!client || !barrels || !count) return BB_ERROR;

    ProtocolRequest req = {
        .command = CMD_LIST_BARRELS,
        .seq = client->next_seq++,
        .key = "",
        .value = ""
    };

    ProtocolResponse resp;
    memset(&resp, 0, sizeof(resp));
    BBResult result = send_request(client, &req, &resp, client->config.timeout_ms);

    if (result == BB_OK) {
        if (resp.status == STATUS_OK) {
            // Handle empty response
            if (!resp.value || resp.value[0] == '\0') {
                *barrels = NULL;
                *count = 0;
                free(resp.value);
                return BB_OK;
            }

            // Parse comma-separated list
            char* data = resp.value;
            size_t num_barrels = 1;

            // Count commas to determine number of barrels
            for (char* p = data; *p; p++) {
                if (*p == ',') num_barrels++;
            }

            // Allocate array
            *barrels = calloc(num_barrels, sizeof(char*));
            if (!*barrels) {
                free(resp.value);
                return BB_ERROR;
            }

            // Parse barrels
            size_t idx = 0;
            char* saveptr;
            char* token = strtok_r(data, ",", &saveptr);
            while (token && idx < num_barrels) {
                (*barrels)[idx] = strdup(token);
                token = strtok_r(NULL, ",", &saveptr);
                idx++;
            }

            *count = idx;
            result = BB_OK;
        } else {
            *barrels = NULL;
            *count = 0;
            result = translate_error(resp.status);
        }
    } else {
        *barrels = NULL;
        *count = 0;
    }

    free(resp.value);
    return result;
}

BBResult bb_drop_barrel(BBClient* client, const char* name) {
    if (!client || !name) return BB_ERROR;

    ProtocolRequest req = {
        .command = CMD_DROP_BARREL,
        .seq = client->next_seq++,
        .key = name,
        .value = ""
    };

    ProtocolResponse resp;
    memset(&resp, 0, sizeof(resp));
    BBResult result = send_request(client, &req, &resp, client->config.timeout_ms);

    if (result == BB_OK) {
        if (resp.status == STATUS_OK) {
            // If we dropped our current barrel, clear it
            if (client->current_barrel && strcmp(client->current_barrel, name) == 0) {
                free(client->current_barrel);
                client->current_barrel = NULL;
            }
            result = BB_OK;
        } else if (resp.status == STATUS_BARREL_NOT_FOUND) {
            result = BB_NO_BARREL;
        } else {
            if (resp.value && resp.value[0]) {
                strncpy(client->last_error, resp.value, sizeof(client->last_error) - 1);
            }
            result = translate_error(resp.status);
        }
    }

    free(resp.value);
    return result;
}

BBResult bb_set(BBClient* client, const char* key, const char* value, int ttl) {
    if (!client || !key || !value) return BB_ERROR;

    ProtocolRequest req = {
        .command = CMD_SET,
        .seq = client->next_seq++,
        .key = key,
        .value = value
    };

    ProtocolResponse resp = {0};
    BBResult result = send_request(client, &req, &resp, client->config.timeout_ms);

    if (result == BB_OK) {
        if (resp.status == STATUS_OK) {
            result = BB_OK;
        } else if (resp.status == STATUS_NO_BARREL) {
            result = BB_NO_BARREL;
        } else {
            result = translate_error(resp.status);
        }
    }

    free(resp.value);
    return result;
}

char* bb_get(BBClient* client, const char* key) {
    if (!client || !key) return NULL;

    ProtocolRequest req = {
        .command = CMD_GET,
        .seq = client->next_seq++,
        .key = key,
        .value = ""
    };

    ProtocolResponse resp = {0};
    BBResult result = send_request(client, &req, &resp, client->config.timeout_ms);

    if (result == BB_OK) {
        if (resp.status == STATUS_OK) {
            return resp.value;  // Caller must free
        } else if (resp.status == STATUS_NOT_FOUND) {
            free(resp.value);
            return NULL;
        } else {
            free(resp.value);
            return NULL;
        }
    }

    free(resp.value);
    return NULL;
}

BBResult bb_delete(BBClient* client, const char* key) {
    if (!client || !key) return BB_ERROR;

    ProtocolRequest req = {
        .command = CMD_DELETE,
        .seq = client->next_seq++,
        .key = key,
        .value = ""
    };

    ProtocolResponse resp = {0};
    BBResult result = send_request(client, &req, &resp, client->config.timeout_ms);

    if (result == BB_OK) {
        if (resp.status == STATUS_OK || resp.status == STATUS_NOT_FOUND) {
            result = BB_OK;  // Deleting non-existent key is OK
        } else if (resp.status == STATUS_NO_BARREL) {
            result = BB_NO_BARREL;
        } else {
            result = translate_error(resp.status);
        }
    }

    free(resp.value);
    return result;
}

bool bb_exists(BBClient* client, const char* key) {
    if (!client || !key) return false;

    ProtocolRequest req = {
        .command = CMD_EXISTS,
        .seq = client->next_seq++,
        .key = key,
        .value = ""
    };

    ProtocolResponse resp = {0};
    BBResult result = send_request(client, &req, &resp, client->config.timeout_ms);

    bool exists = false;
    if (result == BB_OK) {
        exists = (resp.status == STATUS_OK && resp.value && strcmp(resp.value, "true") == 0);
    }

    free(resp.value);
    return exists;
}

BBResult bb_count(BBClient* client, int64_t* count) {
    if (!client || !count) return BB_ERROR;

    ProtocolRequest req = {
        .command = CMD_COUNT,
        .seq = client->next_seq++,
        .key = "",
        .value = ""
    };

    ProtocolResponse resp = {0};
    BBResult result = send_request(client, &req, &resp, client->config.timeout_ms);

    if (result == BB_OK) {
        if (resp.status == STATUS_OK) {
            *count = resp.value ? atoll(resp.value) : 0;
            result = BB_OK;
        } else {
            *count = 0;
            result = translate_error(resp.status);
        }
    } else {
        *count = 0;
    }

    free(resp.value);
    return result;
}

BBResult bb_list_keys(BBClient* client, char*** keys, size_t* count) {
    if (!client || !keys || !count) return BB_ERROR;

    ProtocolRequest req = {
        .command = CMD_LIST_KEYS,
        .seq = client->next_seq++,
        .key = "",
        .value = ""
    };

    ProtocolResponse resp = {0};
    BBResult result = send_request(client, &req, &resp, client->config.timeout_ms);

    if (result == BB_OK) {
        if (resp.status == STATUS_OK) {
            // Parse comma-separated list
            if (!resp.value || resp.value[0] == '\0') {
                *keys = NULL;
                *count = 0;
                free(resp.value);
                return BB_OK;
            }

            char* data = resp.value;
            size_t num_keys = 1;

            // Count commas to determine number of keys
            for (char* p = data; *p; p++) {
                if (*p == ',') num_keys++;
            }

            // Allocate array
            *keys = calloc(num_keys, sizeof(char*));
            if (!*keys) {
                free(resp.value);
                return BB_ERROR;
            }

            // Parse keys
            size_t idx = 0;
            char* saveptr;
            char* token = strtok_r(data, ",", &saveptr);
            while (token && idx < num_keys) {
                (*keys)[idx] = strdup(token);
                token = strtok_r(NULL, ",", &saveptr);
                idx++;
            }

            *count = idx;
            result = BB_OK;
        } else {
            *keys = NULL;
            *count = 0;
            result = translate_error(resp.status);
        }
    } else {
        *keys = NULL;
        *count = 0;
    }

    free(resp.value);
    return result;
}

// Batch operations

BBResult bb_batch_set(BBClient* client, const char** keys, const char** values, size_t count, size_t* success_count) {
    if (!client || !keys || !values || count == 0 || !success_count) return BB_ERROR;

    pthread_mutex_lock(&client->request_lock);

    // Build batch set request
    // Format: [type:1=0x27][seq:4][count:4][keyLen1:2][key1:N][valLen1:4][val1:M]...
    size_t buffer_size = 9;  // type + seq + count
    for (size_t i = 0; i < count; i++) {
        buffer_size += 2 + strlen(keys[i]) + 4 + strlen(values[i]);
    }

    uint8_t* buffer = malloc(buffer_size);
    if (!buffer) {
        pthread_mutex_unlock(&client->request_lock);
        return BB_ERROR;
    }

    size_t offset = 0;
    buffer[offset++] = CMD_BATCH_SET;

    uint32_t seq = client->next_seq++;
    *(uint32_t*)(buffer + offset) = htobe32(seq);
    offset += 4;

    *(uint32_t*)(buffer + offset) = htobe32((uint32_t)count);
    offset += 4;

    for (size_t i = 0; i < count; i++) {
        uint16_t key_len = strlen(keys[i]);
        *(uint16_t*)(buffer + offset) = htobe16(key_len);
        offset += 2;
        memcpy(buffer + offset, keys[i], key_len);
        offset += key_len;

        uint32_t val_len = strlen(values[i]);
        *(uint32_t*)(buffer + offset) = htobe32(val_len);
        offset += 4;
        memcpy(buffer + offset, values[i], val_len);
        offset += val_len;
    }

    if (ws_send_binary(client->ws, buffer, offset) < 0) {
        strncpy(client->last_error, ws_get_error(client->ws), sizeof(client->last_error) - 1);
        free(buffer);
        pthread_mutex_unlock(&client->request_lock);
        return BB_CONNECTION_ERROR;
    }
    free(buffer);

    // Receive response
    uint8_t* response_data = NULL;
    ssize_t response_len = ws_recv_binary(client->ws, &response_data, client->config.timeout_ms);
    if (response_len <= 0) {
        strncpy(client->last_error, "No response from server", sizeof(client->last_error) - 1);
        pthread_mutex_unlock(&client->request_lock);
        return BB_TIMEOUT;
    }

    // Decode batch response: [status:1][seq:4][count:4][status1:1]...[statusN:1]
    if (response_len < 9) {
        free(response_data);
        pthread_mutex_unlock(&client->request_lock);
        return BB_PROTOCOL_ERROR;
    }

    uint8_t status = response_data[0];
    if (status != STATUS_OK) {
        free(response_data);
        pthread_mutex_unlock(&client->request_lock);
        return translate_error(status);
    }

    size_t pos = 5;  // Skip status and seq
    uint32_t result_count = be32toh(*(uint32_t*)(response_data + pos));
    pos += 4;

    *success_count = 0;
    for (uint32_t i = 0; i < result_count && pos < (size_t)response_len; i++) {
        if (response_data[pos] == STATUS_OK) {
            (*success_count)++;
        }
        pos++;
    }

    free(response_data);
    pthread_mutex_unlock(&client->request_lock);
    return BB_OK;
}

BBResult bb_batch_get(BBClient* client, const char** keys, size_t key_count,
                      char*** values, uint8_t** statuses, size_t* result_count) {
    if (!client || !keys || key_count == 0 || !values || !statuses || !result_count) return BB_ERROR;

    pthread_mutex_lock(&client->request_lock);

    // Build batch get request
    // Format: [type:1=0x26][seq:4][count:4][keyLen1:2][key1:N]...[keyLenN:2][keyN:M]
    size_t buffer_size = 9;
    for (size_t i = 0; i < key_count; i++) {
        buffer_size += 2 + strlen(keys[i]);
    }

    uint8_t* buffer = malloc(buffer_size);
    if (!buffer) {
        pthread_mutex_unlock(&client->request_lock);
        return BB_ERROR;
    }

    size_t offset = 0;
    buffer[offset++] = CMD_BATCH_GET;

    uint32_t seq = client->next_seq++;
    *(uint32_t*)(buffer + offset) = htobe32(seq);
    offset += 4;

    *(uint32_t*)(buffer + offset) = htobe32((uint32_t)key_count);
    offset += 4;

    for (size_t i = 0; i < key_count; i++) {
        uint16_t key_len = strlen(keys[i]);
        *(uint16_t*)(buffer + offset) = htobe16(key_len);
        offset += 2;
        memcpy(buffer + offset, keys[i], key_len);
        offset += key_len;
    }

    if (ws_send_binary(client->ws, buffer, offset) < 0) {
        strncpy(client->last_error, ws_get_error(client->ws), sizeof(client->last_error) - 1);
        free(buffer);
        pthread_mutex_unlock(&client->request_lock);
        return BB_CONNECTION_ERROR;
    }
    free(buffer);

    // Receive response
    uint8_t* response_data = NULL;
    ssize_t response_len = ws_recv_binary(client->ws, &response_data, client->config.timeout_ms);
    if (response_len <= 0) {
        strncpy(client->last_error, "No response from server", sizeof(client->last_error) - 1);
        pthread_mutex_unlock(&client->request_lock);
        return BB_TIMEOUT;
    }

    // Decode batch response: [status:1][seq:4][count:4][status1:1][valLen1:4][val1:N]...
    if (response_len < 9) {
        free(response_data);
        pthread_mutex_unlock(&client->request_lock);
        return BB_PROTOCOL_ERROR;
    }

    uint8_t status = response_data[0];
    if (status != STATUS_OK) {
        free(response_data);
        pthread_mutex_unlock(&client->request_lock);
        return translate_error(status);
    }

    size_t pos = 5;  // Skip status and seq
    uint32_t count = be32toh(*(uint32_t*)(response_data + pos));
    pos += 4;

    *values = calloc(count, sizeof(char*));
    *statuses = calloc(count, sizeof(uint8_t));
    if (!*values || !*statuses) {
        free(*values);
        free(*statuses);
        free(response_data);
        pthread_mutex_unlock(&client->request_lock);
        return BB_ERROR;
    }

    *result_count = count;

    for (uint32_t i = 0; i < count && pos + 5 <= (size_t)response_len; i++) {
        (*statuses)[i] = response_data[pos++];

        uint32_t val_len = be32toh(*(uint32_t*)(response_data + pos));
        pos += 4;

        if (pos + val_len <= (size_t)response_len) {
            (*values)[i] = malloc(val_len + 1);
            if ((*values)[i]) {
                memcpy((*values)[i], response_data + pos, val_len);
                (*values)[i][val_len] = '\0';
            }
            pos += val_len;
        }
    }

    free(response_data);
    pthread_mutex_unlock(&client->request_lock);
    return BB_OK;
}

BBResult bb_batch_delete(BBClient* client, const char** keys, size_t count, size_t* success_count) {
    if (!client || !keys || count == 0 || !success_count) return BB_ERROR;

    pthread_mutex_lock(&client->request_lock);

    // Build batch delete request
    // Format: [type:1=0x28][seq:4][count:4][keyLen1:2][key1:N]...[keyLenN:2][keyN:M]
    size_t buffer_size = 9;
    for (size_t i = 0; i < count; i++) {
        buffer_size += 2 + strlen(keys[i]);
    }

    uint8_t* buffer = malloc(buffer_size);
    if (!buffer) {
        pthread_mutex_unlock(&client->request_lock);
        return BB_ERROR;
    }

    size_t offset = 0;
    buffer[offset++] = CMD_BATCH_DELETE;

    uint32_t seq = client->next_seq++;
    *(uint32_t*)(buffer + offset) = htobe32(seq);
    offset += 4;

    *(uint32_t*)(buffer + offset) = htobe32((uint32_t)count);
    offset += 4;

    for (size_t i = 0; i < count; i++) {
        uint16_t key_len = strlen(keys[i]);
        *(uint16_t*)(buffer + offset) = htobe16(key_len);
        offset += 2;
        memcpy(buffer + offset, keys[i], key_len);
        offset += key_len;
    }

    if (ws_send_binary(client->ws, buffer, offset) < 0) {
        strncpy(client->last_error, ws_get_error(client->ws), sizeof(client->last_error) - 1);
        free(buffer);
        pthread_mutex_unlock(&client->request_lock);
        return BB_CONNECTION_ERROR;
    }
    free(buffer);

    // Receive response
    uint8_t* response_data = NULL;
    ssize_t response_len = ws_recv_binary(client->ws, &response_data, client->config.timeout_ms);
    if (response_len <= 0) {
        strncpy(client->last_error, "No response from server", sizeof(client->last_error) - 1);
        pthread_mutex_unlock(&client->request_lock);
        return BB_TIMEOUT;
    }

    // Decode batch response: [status:1][seq:4][count:4][status1:1]...[statusN:1]
    if (response_len < 9) {
        free(response_data);
        pthread_mutex_unlock(&client->request_lock);
        return BB_PROTOCOL_ERROR;
    }

    uint8_t status = response_data[0];
    if (status != STATUS_OK) {
        free(response_data);
        pthread_mutex_unlock(&client->request_lock);
        return translate_error(status);
    }

    size_t pos = 5;  // Skip status and seq
    uint32_t result_count_val = be32toh(*(uint32_t*)(response_data + pos));
    pos += 4;

    *success_count = 0;
    for (uint32_t i = 0; i < result_count_val && pos < (size_t)response_len; i++) {
        if (response_data[pos] == STATUS_OK) {
            (*success_count)++;
        }
        pos++;
    }

    free(response_data);
    pthread_mutex_unlock(&client->request_lock);
    return BB_OK;
}

void bb_free_string(char* str) {
    free(str);
}

void bb_free_string_array(char** array, size_t count) {
    if (!array) return;
    for (size_t i = 0; i < count; i++) {
        free(array[i]);
    }
    free(array);
}

const char* bb_get_last_error(const BBClient* client) {
    return client ? client->last_error : "Invalid client";
}

BBResult bb_get_server_info(const BBClient* client, BBServerInfo* info) {
    if (!client || !info) return BB_ERROR;
    if (!client->handshake_received) return BB_ERROR;

    info->version_major = client->server_info.version_major;
    info->version_minor = client->server_info.version_minor;
    info->server_id = client->server_info.server_id;
    info->plugins = (const char**)client->server_info.plugins;
    info->plugin_count = client->server_info.plugin_count;

    return BB_OK;
}
