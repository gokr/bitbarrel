#ifndef WEBSOCKET_H
#define WEBSOCKET_H

#define _GNU_SOURCE  // For ssize_t and other POSIX features

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>

// WebSocket connection handle
typedef struct BBWebSocket BBWebSocket;

// Message types
typedef enum {
    WS_TEXT = 0x1,
    WS_BINARY = 0x2,
    WS_CLOSE = 0x8,
    WS_PING = 0x9,
    WS_PONG = 0xA
} WSMessageType;

// WebSocket configuration
typedef struct {
    const char* url;        // ws:// or wss:// URL
    int timeout_ms;         // Connection timeout
    bool verify_cert;       // Verify SSL certificate (for wss://)
} WSConfig;

// Create WebSocket configuration with defaults
WSConfig ws_config_default(void);

// Create WebSocket connection
BBWebSocket* ws_create(const WSConfig* config);

// Destroy WebSocket connection
void ws_destroy(BBWebSocket* ws);

// Connect to server
int ws_connect(BBWebSocket* ws);

// Disconnect from server
void ws_disconnect(BBWebSocket* ws);

// Check if connected
bool ws_is_connected(const BBWebSocket* ws);

// Send binary data
int ws_send_binary(BBWebSocket* ws, const uint8_t* data, size_t len);

// Receive binary data (blocking with timeout)
// Returns: number of bytes received, or -1 on error
// Caller must free() the returned data
ssize_t ws_recv_binary(BBWebSocket* ws, uint8_t** data, int timeout_ms);

// Send text data
int ws_send_text(BBWebSocket* ws, const char* text);

// Receive text data (blocking with timeout)
// Returns: string length, or -1 on error
// Caller must free() the returned string
ssize_t ws_recv_text(BBWebSocket* ws, char** text, int timeout_ms);

// Get last error message
const char* ws_get_error(const BBWebSocket* ws);

#endif // WEBSOCKET_H
