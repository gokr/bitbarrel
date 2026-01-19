#ifndef PROTOCOL_H
#define PROTOCOL_H

#define _GNU_SOURCE  // For ssize_t and other POSIX features

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>

// Command types
typedef enum {
    // Data operations
    CMD_GET = 0x01,
    CMD_SET = 0x02,
    CMD_DELETE = 0x03,
    CMD_EXISTS = 0x04,
    CMD_COUNT = 0x05,
    CMD_LIST_KEYS = 0x06,
    CMD_PING = 0x09,

    // Barrel management
    CMD_CREATE_BARREL = 0x10,
    CMD_OPEN_BARREL = 0x11,
    CMD_USE_BARREL = 0x12,
    CMD_CLOSE_BARREL = 0x13,
    CMD_LIST_BARRELS = 0x14,
    CMD_DROP_BARREL = 0x15,

    // Configuration commands
    CMD_GET_BARREL_CONFIG = 0x16,
    CMD_SET_BARREL_CONFIG = 0x17,
    CMD_GET_BARREL_STATS = 0x18,

    // Range queries
    CMD_RANGE_QUERY = 0x21,
    CMD_PREFIX_QUERY = 0x22,
    CMD_RANGE_COUNT = 0x23,
    CMD_RANGE_KEYS = 0x24,
    CMD_PREFIX_KEYS = 0x25,

    // Batch operations
    CMD_BATCH_GET = 0x26,
    CMD_BATCH_SET = 0x27,
    CMD_BATCH_DELETE = 0x28,

    // Reference traversal
    CMD_TRAVERSE = 0x20,

    // Pub/Sub commands
    CMD_SUBSCRIBE = 0x40,
    CMD_UNSUBSCRIBE = 0x41,
    CMD_PUBLISH = 0x42,
    CMD_LIST_SUBSCRIBERS = 0x43,
    CMD_HISTORY = 0x44,
    CMD_LIST_TOPICS = 0x45,
    CMD_PRESENCE = 0x46,

    // Pub/Sub events (response only)
    CMD_PUBSUB_EVENT = 0xFF
} CommandType;

// Response status
typedef enum {
    STATUS_OK = 0x00,
    STATUS_NOT_FOUND = 0x01,
    STATUS_ERROR = 0x02,
    STATUS_INVALID = 0x03,
    STATUS_NO_BARREL = 0x04,
    STATUS_BARREL_EXISTS = 0x05,
    STATUS_BARREL_NOT_FOUND = 0x06,
    STATUS_UNAUTHORIZED = 0x07
} ResponseStatus;

// Request structure
typedef struct {
    uint8_t command;
    uint32_t seq;
    const char* key;
    const char* value;
} ProtocolRequest;

// Response structure
typedef struct {
    uint8_t status;
    uint32_t seq;
    char* value;
} ProtocolResponse;

// Encode request into buffer
// Returns: number of bytes written, or -1 on error
// Buffer must be large enough to hold the encoded request
ssize_t encode_request(uint8_t* buffer, const ProtocolRequest* req, int32_t ttl);

// Decode response from buffer
// Returns: 0 on success, -1 on error
// Caller must free response->value
int decode_response(const uint8_t* buffer, size_t len, ProtocolResponse* resp);

// Check if buffer contains a pub/sub event
bool is_pubsub_event(const uint8_t* buffer, size_t len);

// Encode range query request
// Returns: number of bytes written, or -1 on error
ssize_t encode_range_request(uint8_t* buffer, const char* start_key,
                             const char* end_key, size_t limit, const char* cursor);

// Encode prefix query request
// Returns: number of bytes written, or -1 on error
ssize_t encode_prefix_request(uint8_t* buffer, const char* prefix,
                              size_t limit, const char* cursor);

// Encode pub/sub event (for sending publish)
// Returns: number of bytes written, or -1 on error
ssize_t encode_publish_request(uint8_t* buffer, uint32_t seq, const char* topic,
                               const char* data);

// Encode subscribe request
typedef enum {
    SUB_MODE_EXACT = 0,
    SUB_MODE_PATTERN = 1
} SubscribeMode;

ssize_t encode_subscribe_request(uint8_t* buffer, uint32_t seq, SubscribeMode mode,
                                 const char* topic, const char* pattern);

// Encode history request
ssize_t encode_history_request(uint8_t* buffer, const char* topic, int limit, int since_seq);

// Encode presence request
ssize_t encode_presence_request(uint8_t* buffer, int operation);

// Helper functions for big-endian encoding
// Use system byte swap functions if available
#ifdef __linux__
#include <endian.h>
// Don't redefine if already defined
#ifndef htobe16
#define htobe16(x) htobe16(x)
#define htobe32(x) htobe32(x)
#define htobe64(x) htobe64(x)
#define be16toh(x) be16toh(x)
#define be32toh(x) be32toh(x)
#endif
#else
// Fallback implementations for non-Linux systems
static inline uint16_t htobe16(uint16_t host) {
    union {
        uint16_t u16;
        uint8_t u8[2];
    } src, dst;
    src.u16 = host;
    dst.u8[0] = src.u8[1];
    dst.u8[1] = src.u8[0];
    return dst.u16;
}

static inline uint32_t htobe32(uint32_t host) {
    union {
        uint32_t u32;
        uint8_t u8[4];
    } src, dst;
    src.u32 = host;
    dst.u8[0] = src.u8[3];
    dst.u8[1] = src.u8[2];
    dst.u8[2] = src.u8[1];
    dst.u8[3] = src.u8[0];
    return dst.u32;
}

static inline uint64_t htobe64(uint64_t host) {
    union {
        uint64_t u64;
        uint8_t u8[8];
    } src, dst;
    src.u64 = host;
    for (int i = 0; i < 8; i++) {
        dst.u8[i] = src.u8[7 - i];
    }
    return dst.u64;
}

static inline uint16_t be16toh(uint16_t big) {
    union {
        uint16_t u16;
        uint8_t u8[2];
    } src, dst;
    src.u16 = big;
    dst.u8[0] = src.u8[1];
    dst.u8[1] = src.u8[0];
    return dst.u16;
}

static inline uint32_t be32toh(uint32_t big) {
    union {
        uint32_t u32;
        uint8_t u8[4];
    } src, dst;
    src.u32 = big;
    dst.u8[0] = src.u8[3];
    dst.u8[1] = src.u8[2];
    dst.u8[2] = src.u8[1];
    dst.u8[3] = src.u8[0];
    return dst.u32;
}
#endif

#endif // PROTOCOL_H
