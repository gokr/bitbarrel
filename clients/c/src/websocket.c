#define _GNU_SOURCE  // For POSIX features

#include "websocket.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <errno.h>
#include <poll.h>
#include <openssl/ssl.h>
#include <openssl/err.h>

#define WS_MAX_FRAME_SIZE (16 * 1024 * 1024)  // 16MB max frame

struct BBWebSocket {
    int socket_fd;
    SSL* ssl;
    SSL_CTX* ssl_ctx;
    char* url;
    char* hostname;
    int port;
    bool use_ssl;
    bool connected;
    int timeout_ms;
    char error_msg[256];
};

WSConfig ws_config_default(void) {
    WSConfig config = {
        .url = "ws://localhost:7687",
        .timeout_ms = 5000,
        .verify_cert = true
    };
    return config;
}

static bool parse_url(const char* url, char** hostname, int* port, bool* use_ssl) {
    if (strncmp(url, "ws://", 5) == 0) {
        *use_ssl = false;
        url += 5;
        *port = 80;
    } else if (strncmp(url, "wss://", 6) == 0) {
        *use_ssl = true;
        url += 6;
        *port = 443;
    } else {
        return false;
    }

    // Find host part (until : or /)
    const char* host_end = strchr(url, ':');
    if (!host_end) {
        host_end = strchr(url, '/');
    }
    if (!host_end) {
        host_end = url + strlen(url);
    }

    size_t host_len = host_end - url;
    *hostname = malloc(host_len + 1);
    if (!*hostname) return false;

    strncpy(*hostname, url, host_len);
    (*hostname)[host_len] = '\0';

    // Parse port if specified
    if (*host_end == ':') {
        *port = atoi(host_end + 1);
    }

    return true;
}

static bool websocket_handshake(BBWebSocket* ws) {
    // For BitBarrel, we connect directly without WebSocket handshake
    // The protocol runs over raw TCP with binary framing
    return true;
}

BBWebSocket* ws_create(const WSConfig* config) {
    BBWebSocket* ws = calloc(1, sizeof(BBWebSocket));
    if (!ws) return NULL;

    ws->url = strdup(config->url);
    if (!ws->url) {
        free(ws);
        return NULL;
    }

    if (!parse_url(config->url, &ws->hostname, &ws->port, &ws->use_ssl)) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Invalid URL: %s", config->url);
        free(ws->url);
        free(ws);
        return NULL;
    }

    ws->timeout_ms = config->timeout_ms;
    return ws;
}

void ws_destroy(BBWebSocket* ws) {
    if (!ws) return;

    if (ws->connected) {
        ws_disconnect(ws);
    }

    if (ws->ssl) {
        SSL_free(ws->ssl);
    }
    if (ws->ssl_ctx) {
        SSL_CTX_free(ws->ssl_ctx);
    }
    if (ws->socket_fd >= 0) {
        close(ws->socket_fd);
    }

    free(ws->hostname);
    free(ws->url);
    free(ws);
}

int ws_connect(BBWebSocket* ws) {
    if (ws->connected) {
        return 0;
    }

    // Resolve hostname
    struct hostent* host = gethostbyname(ws->hostname);
    if (!host) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Failed to resolve hostname: %s", ws->hostname);
        return -1;
    }

    // Create socket
    ws->socket_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (ws->socket_fd < 0) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Failed to create socket: %s", strerror(errno));
        return -1;
    }

    // Set timeout
    struct timeval timeout;
    timeout.tv_sec = ws->timeout_ms / 1000;
    timeout.tv_usec = (ws->timeout_ms % 1000) * 1000;
    setsockopt(ws->socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(ws->socket_fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    // Connect
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(ws->port);
    memcpy(&addr.sin_addr, host->h_addr_list[0], host->h_length);

    if (connect(ws->socket_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Failed to connect: %s", strerror(errno));
        close(ws->socket_fd);
        ws->socket_fd = -1;
        return -1;
    }

    // For BitBarrel, we don't do a WebSocket handshake
    // We directly send/receive binary data using the BitBarrel protocol
    ws->connected = true;

    if (!websocket_handshake(ws)) {
        ws_disconnect(ws);
        return -1;
    }

    return 0;
}

void ws_disconnect(BBWebSocket* ws) {
    if (!ws->connected) return;

    ws->connected = false;

    if (ws->ssl) {
        SSL_shutdown(ws->ssl);
    }

    if (ws->socket_fd >= 0) {
        close(ws->socket_fd);
        ws->socket_fd = -1;
    }
}

bool ws_is_connected(const BBWebSocket* ws) {
    return ws && ws->connected;
}

int ws_send_binary(BBWebSocket* ws, const uint8_t* data, size_t len) {
    if (!ws->connected) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Not connected");
        return -1;
    }

    ssize_t sent = send(ws->socket_fd, data, len, 0);
    if (sent < 0) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Send failed: %s", strerror(errno));
        ws->connected = false;
        return -1;
    }

    return 0;
}

ssize_t ws_recv_binary(BBWebSocket* ws, uint8_t** data, int timeout_ms) {
    if (!ws->connected) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Not connected");
        return -1;
    }

    // Use poll for timeout
    struct pollfd pfd = {
        .fd = ws->socket_fd,
        .events = POLLIN
    };

    int ret = poll(&pfd, 1, timeout_ms);
    if (ret < 0) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Poll failed: %s", strerror(errno));
        return -1;
    }
    if (ret == 0) {
        return 0;  // Timeout
    }

    // Allocate buffer for receive
    size_t buffer_size = 64 * 1024;  // 64KB initial buffer
    *data = malloc(buffer_size);
    if (!*data) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Memory allocation failed");
        return -1;
    }

    ssize_t received = recv(ws->socket_fd, *data, buffer_size, 0);
    if (received < 0) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Receive failed: %s", strerror(errno));
        free(*data);
        *data = NULL;
        ws->connected = false;
        return -1;
    }
    if (received == 0) {
        // Connection closed
        free(*data);
        *data = NULL;
        ws->connected = false;
        return -1;
    }

    return received;
}

int ws_send_text(BBWebSocket* ws, const char* text) {
    return ws_send_binary(ws, (const uint8_t*)text, strlen(text));
}

ssize_t ws_recv_text(BBWebSocket* ws, char** text, int timeout_ms) {
    uint8_t* data = NULL;
    ssize_t len = ws_recv_binary(ws, &data, timeout_ms);

    if (len > 0) {
        *text = (char*)data;
        // Ensure null termination
        if (len > 0 && (*text)[len-1] != '\0') {
            char* temp = realloc(*text, len + 1);
            if (temp) {
                *text = temp;
                (*text)[len] = '\0';
            }
        }
    } else {
        *text = NULL;
    }

    return len;
}

const char* ws_get_error(const BBWebSocket* ws) {
    return ws ? ws->error_msg : "Invalid WebSocket";
}
