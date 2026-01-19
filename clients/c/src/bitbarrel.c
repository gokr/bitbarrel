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

    // Wait for welcome message (simple ping to verify connection)
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

    ProtocolResponse resp;
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

    // Receive response
    uint8_t* response_data = NULL;
    ssize_t response_len = ws_recv_binary(client->ws, &response_data, timeout_ms);
    if (response_len <= 0) {
        strncpy(client->last_error, "No response from server", sizeof(client->last_error) - 1);
        pthread_mutex_unlock(&client->request_lock);
        return BB_TIMEOUT;
    }

    int decode_ret = decode_response(response_data, response_len, resp);
    free(response_data);

    if (decode_ret < 0) {
        strncpy(client->last_error, "Failed to decode response", sizeof(client->last_error) - 1);
        pthread_mutex_unlock(&client->request_lock);
        return BB_PROTOCOL_ERROR;
    }

    pthread_mutex_unlock(&client->request_lock);
    return BB_OK;
}

BBResult bb_create_barrel(BBClient* client, const char* name, BBMode mode) {
    if (!client || !name) return BB_ERROR;

    ProtocolRequest req = {
        .command = CMD_CREATE_BARREL,
        .seq = client->next_seq++,
        .key = name,
        .value = (mode == BM_CRITBIT) ? "bmCritBit" : "bmHash"
    };

    ProtocolResponse resp;
    BBResult result = send_request(client, &req, &resp, client->config.timeout_ms);

    if (result == BB_OK) {
        if (resp.status == STATUS_OK) {
            result = BB_OK;
        } else if (resp.status == STATUS_BARREL_EXISTS) {
            result = BB_BARREL_EXISTS;
        } else {
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

    ProtocolResponse resp;
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

    ProtocolResponse resp;
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

    ProtocolResponse resp;
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
    BBResult result = send_request(client, &req, &resp, client->config.timeout_ms);

    if (result == BB_OK) {
        if (resp.status == STATUS_OK) {
            // Parse comma-separated list
            char* data = resp.value;
            size_t num_barrels = 1;  // At least empty string

            // Count commas
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

BBResult bb_set(BBClient* client, const char* key, const char* value, int ttl) {
    if (!client || !key || !value) return BB_ERROR;

    ProtocolRequest req = {
        .command = CMD_SET,
        .seq = client->next_seq++,
        .key = key,
        .value = value
    };

    ProtocolResponse resp;
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

    ProtocolResponse resp;
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

    ProtocolResponse resp;
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

    ProtocolResponse resp;
    BBResult result = send_request(client, &req, &resp, client->config.timeout_ms);

    bool exists = false;
    if (result == BB_OK) {
        exists = (resp.status == STATUS_OK && strcmp(resp.value, "true") == 0);
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

    ProtocolResponse resp;
    BBResult result = send_request(client, &req, &resp, client->config.timeout_ms);

    if (result == BB_OK) {
        if (resp.status == STATUS_OK) {
            *count = atoll(resp.value);
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
