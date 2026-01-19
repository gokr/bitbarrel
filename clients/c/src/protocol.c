#define _GNU_SOURCE

#include "protocol.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

// Encode request into buffer
// Format: [type:1][seq:4][flags:1][keyLen:2][key:N][valLen:4][value:M][ttl:4|0]
ssize_t encode_request(uint8_t* buffer, const ProtocolRequest* req, int32_t ttl) {
    size_t offset = 0;

    // Command (1 byte)
    buffer[offset++] = req->command;

    // Sequence number (4 bytes, big-endian)
    *(uint32_t*)(buffer + offset) = htobe32(req->seq);
    offset += 4;

    // Flags (1 byte)
    uint8_t flags = 0;
    if (ttl >= 0) {
        flags |= 0x01;  // TTL flag
    }
    buffer[offset++] = flags;

    // Key length (2 bytes, big-endian) and key
    uint16_t key_len = req->key ? strlen(req->key) : 0;
    *(uint16_t*)(buffer + offset) = htobe16(key_len);
    offset += 2;

    if (key_len > 0) {
        memcpy(buffer + offset, req->key, key_len);
        offset += key_len;
    }

    // Value length (4 bytes, big-endian) and value
    uint32_t val_len = req->value ? strlen(req->value) : 0;
    *(uint32_t*)(buffer + offset) = htobe32(val_len);
    offset += 4;

    if (val_len > 0) {
        memcpy(buffer + offset, req->value, val_len);
        offset += val_len;
    }

    // TTL (4 bytes, big-endian, optional)
    if (ttl >= 0) {
        *(uint32_t*)(buffer + offset) = htobe32(ttl);
        offset += 4;
    }

    return offset;
}

// Decode response from buffer
// Format: [status:1][seq:4][valLen:4][value:M]
int decode_response(const uint8_t* buffer, size_t len, ProtocolResponse* resp) {
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

    // Value
    if (val_len > 0) {
        resp->value = malloc(val_len + 1);
        if (!resp->value) return -1;

        memcpy(resp->value, buffer + offset, val_len);
        resp->value[val_len] = '\0';
    } else {
        resp->value = strdup("");
        if (!resp->value) return -1;
    }

    return 0;
}

// Check if buffer contains a pub/sub event
bool is_pubsub_event(const uint8_t* buffer, size_t len) {
    if (len < 1) return false;
    return buffer[0] == CMD_PUBSUB_EVENT;
}

// Encode range query request
ssize_t encode_range_request(uint8_t* buffer, const char* start_key,
                             const char* end_key, size_t limit, const char* cursor) {
    // Format: [startKey][0][endKey][0][limit:8][cursor][0]
    size_t offset = 0;

    // Start key
    if (start_key) {
        size_t len = strlen(start_key);
        memcpy(buffer + offset, start_key, len);
        offset += len;
    }
    buffer[offset++] = 0;  // Null terminator

    // End key
    if (end_key) {
        size_t len = strlen(end_key);
        memcpy(buffer + offset, end_key, len);
        offset += len;
    }
    buffer[offset++] = 0;  // Null terminator

    // Limit (8 bytes, big-endian)
    *(uint64_t*)(buffer + offset) = htobe64(limit);
    offset += 8;

    // Cursor
    if (cursor) {
        size_t len = strlen(cursor);
        memcpy(buffer + offset, cursor, len);
        offset += len;
    }
    buffer[offset++] = 0;  // Null terminator

    return offset;
}

// Encode prefix query request
ssize_t encode_prefix_request(uint8_t* buffer, const char* prefix,
                              size_t limit, const char* cursor) {
    // Same format as range request, but with empty start_key
    return encode_range_request(buffer, prefix ? prefix : "", "", limit, cursor);
}

// Encode publish request
ssize_t encode_publish_request(uint8_t* buffer, uint32_t seq, const char* topic,
                               const char* data) {
    // Format for publish: Command is handled at request level
    // This encodes just the payload: [topic][0][data]
    size_t offset = 0;

    // Topic
    if (topic) {
        size_t len = strlen(topic);
        memcpy(buffer + offset, topic, len);
        offset += len;
    }
    buffer[offset++] = 0;  // Null terminator

    // Data
    if (data) {
        size_t len = strlen(data);
        memcpy(buffer + offset, data, len);
        offset += len;
    }

    return offset;
}

// Encode subscribe request
ssize_t encode_subscribe_request(uint8_t* buffer, uint32_t seq, SubscribeMode mode,
                                 const char* topic, const char* pattern) {
    // Format: [mode:1][topic][0] or [mode:1][pattern][0]
    size_t offset = 0;

    // Mode (1 byte)
    buffer[offset++] = mode;

    // Topic or pattern
    const char* str = (mode == SUB_MODE_EXACT) ? topic : pattern;
    if (str) {
        size_t len = strlen(str);
        memcpy(buffer + offset, str, len);
        offset += len;
    }
    buffer[offset++] = 0;  // Null terminator

    return offset;
}

// Encode history request
ssize_t encode_history_request(uint8_t* buffer, const char* topic, int limit, int since_seq) {
    // Format: [topicLen:2][topic][count:4][sinceSeq:8]
    size_t offset = 0;

    // Topic length (2 bytes, big-endian)
    uint16_t topic_len = strlen(topic);
    *(uint16_t*)(buffer + offset) = htobe16(topic_len);
    offset += 2;

    // Topic
    memcpy(buffer + offset, topic, topic_len);
    offset += topic_len;

    // Limit (4 bytes, big-endian)
    *(uint32_t*)(buffer + offset) = htobe32(limit);
    offset += 4;

    // Since sequence (8 bytes, big-endian)
    *(uint64_t*)(buffer + offset) = htobe64(since_seq);
    offset += 8;

    return offset;
}

// Encode presence request
ssize_t encode_presence_request(uint8_t* buffer, int operation) {
    // Format: [operation:1]
    buffer[0] = operation;
    return 1;
}
