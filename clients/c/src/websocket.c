#define _GNU_SOURCE  // For POSIX features

#include "websocket.h"

#ifdef USE_LIBWEBSOCKETS
#include <libwebsockets.h>
#else
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
#include <fcntl.h>
#include <openssl/sha.h>
#endif

#define WS_MAX_FRAME_SIZE (16 * 1024 * 1024)  // 16MB max frame

#ifdef USE_LIBWEBSOCKETS
// libwebsockets implementation
struct BBWebSocket {
    struct lws* wsi;
    struct lws_context* context;
    char* url;
    char* hostname;
    int port;
    bool use_ssl;
    bool connected;
    int timeout_ms;
    char error_msg[256];

    // Receive state - message queue for handling multiple arriving messages
    uint8_t* recv_buffer;      // Current accumulating message
    size_t recv_len;           // Current message length
    size_t recv_capacity;      // Current buffer capacity
    bool recv_complete;        // Current message complete flag

    uint8_t* queue_buffer;     // Queued complete message buffer
    size_t queue_len;          // Length of queued data
    size_t queue_capacity;     // Queued buffer capacity
    bool queue_complete;       // Queued message complete flag
};

// Forward declarations for libwebsockets event handler
static int ws_event_callback(struct lws* wsi, enum lws_callback_reasons reason,
                            void* user, void* in, size_t len);

static const struct lws_protocols protocols[] = {
    {
        "bitbarrel-protocol",
        ws_event_callback,
        0,
        0,
    },
    { NULL, NULL, 0, 0 }
};

static int ws_event_callback(struct lws* wsi, enum lws_callback_reasons reason,
                            void* user, void* in, size_t len) {
    BBWebSocket* ws = (BBWebSocket*)lws_context_user(lws_get_context(wsi));

    switch (reason) {
        case LWS_CALLBACK_CLIENT_RECEIVE:
            if (ws) {
                // If we have space for a new message (either current buffer free or queue free)
                if (!ws->recv_complete && !ws->queue_complete) {
                    // Append received data to current buffer
                    size_t needed = ws->recv_len + len;
                    if (needed > ws->recv_capacity) {
                        size_t new_cap = ws->recv_capacity ? ws->recv_capacity * 2 : 4096;
                        while (new_cap < needed) new_cap *= 2;
                        uint8_t* new_buf = realloc(ws->recv_buffer, new_cap);
                        if (!new_buf) return -1;
                        ws->recv_buffer = new_buf;
                        ws->recv_capacity = new_cap;
                    }
                    memcpy(ws->recv_buffer + ws->recv_len, in, len);
                    ws->recv_len += len;

                    // Check if this is the final fragment of the message
                    if (lws_is_final_fragment(wsi)) {
                        ws->recv_complete = true;
                    }
                } else if (ws->recv_complete && !ws->queue_complete) {
                    // Current message is complete but not consumed yet, queue the new message
                    size_t needed = ws->queue_len + len;
                    if (needed > ws->queue_capacity) {
                        size_t new_cap = ws->queue_capacity ? ws->queue_capacity * 2 : 4096;
                        while (new_cap < needed) new_cap *= 2;
                        uint8_t* new_buf = realloc(ws->queue_buffer, new_cap);
                        if (!new_buf) return -1;
                        ws->queue_buffer = new_buf;
                        ws->queue_capacity = new_cap;
                    }
                    memcpy(ws->queue_buffer + ws->queue_len, in, len);
                    ws->queue_len += len;

                    if (lws_is_final_fragment(wsi)) {
                        ws->queue_complete = true;
                    }
                }
                // If both recv_complete and queue_complete are true, ignore additional data
                // until the queue is consumed
            }
            break;

        case LWS_CALLBACK_CLIENT_CLOSED:
        case LWS_CALLBACK_WSI_DESTROY:
            if (ws) {
                ws->connected = false;
                ws->recv_complete = true;
            }
            break;

        case LWS_CALLBACK_SERVER_WRITEABLE:
        case LWS_CALLBACK_ESTABLISHED:
        case LWS_CALLBACK_CONNECTING:
        case LWS_CALLBACK_CLIENT_ESTABLISHED:
            if (ws && reason == LWS_CALLBACK_CLIENT_ESTABLISHED) {
                ws->connected = true;
            }
            break;

        default:
            break;
    }

    return 0;
}

WSConfig ws_config_default(void) {
    WSConfig config = {
        .url = "ws://localhost:7687",
        .timeout_ms = 5000,
        .verify_cert = true
    };
    return config;
}

BBWebSocket* ws_create(const WSConfig* config) {
    BBWebSocket* ws = calloc(1, sizeof(BBWebSocket));
    if (!ws) return NULL;

    ws->url = strdup(config->url);
    if (!ws->url) {
        free(ws);
        return NULL;
    }

    ws->timeout_ms = config->timeout_ms;
    ws->use_ssl = strncmp(config->url, "wss://", 6) == 0;

    return ws;
}

void ws_destroy(BBWebSocket* ws) {
    if (!ws) return;

    if (ws->connected) {
        ws_disconnect(ws);
    }

    if (ws->context) {
        lws_context_destroy(ws->context);
    }

    free(ws->recv_buffer);
    free(ws->url);
    free(ws);
}

int ws_connect(BBWebSocket* ws) {
    if (ws->connected) return 0;

    // Initialize libwebsockets context
    struct lws_context_creation_info info = {
        .options = LWS_SERVER_OPTION_DO_SSL_GLOBAL_INIT,
        .port = CONTEXT_PORT_NO_LISTEN,
        .protocols = protocols,
        .user = ws,
    };

    ws->context = lws_create_context(&info);
    if (!ws->context) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Failed to create libwebsockets context");
        return -1;
    }

    // Connect
    struct lws_client_connect_info ccinfo = {
        .context = ws->context,
        .address = "localhost",
        .port = 9876,
        .path = "/ws",
        .host = "localhost",
        .origin = "localhost",
        .protocol = "bitbarrel-protocol",
        .alpn = "http/1.1",
    };

    // Parse URL for host and port
    const char* url = ws->use_ssl ? ws->url + 6 : ws->url + 5;  // Skip "ws://" or "wss://"
    const char* colon = strchr(url, ':');
    const char* slash = strchr(url, '/');

    if (colon && (!slash || colon < slash)) {
        size_t host_len = colon - url;
        char host[256];
        strncpy(host, url, host_len);
        host[host_len] = '\0';
        ccinfo.port = atoi(colon + 1);
        ccinfo.address = strdup(host);
        ccinfo.host = ccinfo.address;
    } else {
        ccinfo.port = ws->use_ssl ? 443 : 80;
    }

    if (slash) {
        char path[256];
        strncpy(path, slash, sizeof(path) - 1);
        path[sizeof(path) - 1] = '\0';
        ccinfo.path = strdup(path);
    }

    ws->wsi = lws_client_connect_via_info(&ccinfo);
    if (!ws->wsi) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Failed to initiate WebSocket connection");
        lws_context_destroy(ws->context);
        ws->context = NULL;
        return -1;
    }

    // Wait for connection with timeout
    time_t start = time(NULL);
    while (!ws->connected && (time(NULL) - start) < (ws->timeout_ms / 1000)) {
        lws_service(ws->context, 0);
        usleep(10000);  // 10ms
    }

    if (!ws->connected) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "WebSocket connection timeout");
        lws_context_destroy(ws->context);
        ws->context = NULL;
        return -1;
    }

    return 0;
}

void ws_disconnect(BBWebSocket* ws) {
    if (!ws->connected) return;

    if (ws->wsi) {
        lws_close_reason(ws->wsi, LWS_CLOSE_STATUS_NORMAL, NULL, 0);
    }

    ws->connected = false;
}

bool ws_is_connected(const BBWebSocket* ws) {
    return ws && ws->connected;
}

int ws_send_binary(BBWebSocket* ws, const uint8_t* data, size_t len) {
    if (!ws->connected || !ws->wsi) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Not connected");
        return -1;
    }

    unsigned char* buf = malloc(LWS_PRE + len);
    if (!buf) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Memory allocation failed");
        return -1;
    }

    memcpy(buf + LWS_PRE, data, len);

    int n = lws_write(ws->wsi, buf + LWS_PRE, len, LWS_WRITE_BINARY);
    free(buf);

    if (n < (int)len) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Send failed");
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

    // Check if we already have a complete message waiting
    if (ws->recv_complete && ws->recv_len > 0) {
        *data = malloc(ws->recv_len);
        if (!*data) {
            snprintf(ws->error_msg, sizeof(ws->error_msg), "Memory allocation failed");
            return -1;
        }
        memcpy(*data, ws->recv_buffer, ws->recv_len);
        size_t result_len = ws->recv_len;

        // Reset buffer after consuming data
        ws->recv_len = 0;
        ws->recv_complete = false;

        // If we have a queued complete message, move it to recv buffer
        if (ws->queue_complete && ws->queue_len > 0) {
            // Move queue to recv buffer
            if (ws->queue_len > ws->recv_capacity) {
                uint8_t* new_buf = realloc(ws->recv_buffer, ws->queue_len);
                if (new_buf) {
                    ws->recv_buffer = new_buf;
                    ws->recv_capacity = ws->queue_len;
                } else {
                    // Keep old buffer, will be replaced later
                }
            }
            memcpy(ws->recv_buffer, ws->queue_buffer, ws->queue_len);
            ws->recv_len = ws->queue_len;
            ws->recv_complete = true;
            // Free queue buffer
            free(ws->queue_buffer);
            ws->queue_buffer = NULL;
            ws->queue_len = 0;
            ws->queue_capacity = 0;
            ws->queue_complete = false;
        }

        return (ssize_t)result_len;
    }

    // Drain any pending data before starting new receive
    if (ws->recv_complete) {
        free(ws->queue_buffer);
        ws->queue_buffer = NULL;
        ws->queue_len = 0;
        ws->queue_capacity = 0;
        ws->queue_complete = false;
    }

    // Reset receive state for new message
    ws->recv_len = 0;
    ws->recv_complete = false;

    time_t start = time(NULL);
    time_t timeout_sec = timeout_ms / 1000;
    if (timeout_sec < 1) timeout_sec = 1;

    // Wait for a complete message (final fragment received)
    while (!ws->recv_complete && (time(NULL) - start) < timeout_sec) {
        lws_service(ws->context, 50);  // 50ms interval

        if (!ws->connected) {
            snprintf(ws->error_msg, sizeof(ws->error_msg), "Connection closed during receive");
            return -1;
        }
        usleep(10000);  // 10ms
    }

    if (!ws->recv_complete || ws->recv_len == 0) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "WebSocket receive timeout");
        return -1;  // No complete message received
    }

    *data = malloc(ws->recv_len);
    if (!*data) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Memory allocation failed");
        return -1;
    }

    memcpy(*data, ws->recv_buffer, ws->recv_len);
    size_t result_len = ws->recv_len;

    // Reset buffer after consuming data
    ws->recv_len = 0;
    ws->recv_complete = false;

    // If we have a queued complete message, move it to recv buffer
    if (ws->queue_complete && ws->queue_len > 0) {
        // Move queue to recv buffer
        if (ws->queue_len > ws->recv_capacity) {
            uint8_t* new_buf = realloc(ws->recv_buffer, ws->queue_len);
            if (new_buf) {
                ws->recv_buffer = new_buf;
                ws->recv_capacity = ws->queue_len;
            } else {
                // Keep old buffer, will be replaced later
            }
        }
        memcpy(ws->recv_buffer, ws->queue_buffer, ws->queue_len);
        ws->recv_len = ws->queue_len;
        ws->recv_complete = true;
        // Free queue buffer
        free(ws->queue_buffer);
        ws->queue_buffer = NULL;
        ws->queue_len = 0;
        ws->queue_capacity = 0;
        ws->queue_complete = false;
    }

    return (ssize_t)result_len;
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

#else
// ---------------------------------------------------------------------
// Fallback: Built-in simple WebSocket implementation
// This will be used if libwebsockets is not installed
// ---------------------------------------------------------------------

#define WS_GUID "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

struct BBWebSocket {
    int socket_fd;
    char* url;
    char* hostname;
    char* path;
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

static bool parse_url(const char* url, char** hostname, char** path, int* port, bool* use_ssl) {
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

    if (*host_end == '/') {
        const char* path_start = host_end;
        size_t path_len = strlen(path_start);
        *path = malloc(path_len + 1);
        if (!*path) {
            free(*hostname);
            return false;
        }
        strncpy(*path, path_start, path_len);
        (*path)[path_len] = '\0';
    } else {
        *path = strdup("/");
        if (!*path) {
            free(*hostname);
            return false;
        }
    }

    if (*host_end == ':') {
        *port = atoi(host_end + 1);
    }

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

    if (!parse_url(config->url, &ws->hostname, &ws->path, &ws->port, &ws->use_ssl)) {
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

    if (ws->socket_fd >= 0) {
        close(ws->socket_fd);
        ws->socket_fd = -1;
    }

    free(ws->hostname);
    free(ws->path);
    free(ws->url);
    free(ws);
}

static bool ws_send_http_handshake(BBWebSocket* ws) {
    char challenge[24];
    srand(time(NULL));
    for (int i = 0; i < 24; i++) {
        challenge[i] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"[rand() % 64];
    }
    challenge[24] = '\0';

    char request[512];
    int len = snprintf(request, sizeof(request),
        "GET %s HTTP/1.1\r\n"
        "Host: %s\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: %s\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n",
        ws->path, ws->hostname, challenge);

    if (len < 0 || len >= (int)sizeof(request)) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Handshake request too long");
        return false;
    }

    ssize_t sent = send(ws->socket_fd, request, len, 0);
    if (sent != len) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Failed to send handshake: %s", strerror(errno));
        return false;
    }

    struct pollfd pfd = {.fd = ws->socket_fd, .events = POLLIN};
    if (poll(&pfd, 1, ws->timeout_ms) <= 0) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Handshake response timeout");
        return false;
    }

    char response[1024];
    ssize_t received = recv(ws->socket_fd, response, sizeof(response) - 1, 0);
    if (received <= 0) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Failed to receive handshake: %s", strerror(errno));
        return false;
    }
    response[received] = '\0';

    if (strstr(response, "HTTP/1.1 101") == NULL && strstr(response, "HTTP/1.0 101") == NULL) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "WebSocket upgrade failed: %s", strstr(response, "HTTP"));
        return false;
    }

    if (strstr(response, "Upgrade:") == NULL || strcasestr(response, "websocket") == NULL) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "WebSocket upgrade not confirmed");
        return false;
    }

    return true;
}

int ws_connect(BBWebSocket* ws) {
    if (ws->connected) return 0;

    struct hostent* host = gethostbyname(ws->hostname);
    if (!host) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Failed to resolve hostname: %s", ws->hostname);
        return -1;
    }

    ws->socket_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (ws->socket_fd < 0) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Failed to create socket: %s", strerror(errno));
        return -1;
    }

    struct timeval timeout;
    timeout.tv_sec = ws->timeout_ms / 1000;
    timeout.tv_usec = (ws->timeout_ms % 1000) * 1000;
    setsockopt(ws->socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(ws->socket_fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

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

    if (!ws_send_http_handshake(ws)) {
        close(ws->socket_fd);
        ws->socket_fd = -1;
        return -1;
    }

    ws->connected = true;
    return 0;
}

void ws_disconnect(BBWebSocket* ws) {
    if (!ws->connected) return;

    uint8_t close_frame[2] = {0x88, 0x00};
    send(ws->socket_fd, close_frame, 2, 0);

    ws->connected = false;

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

    uint8_t header[14];
    size_t header_len = 2;
    size_t i = 0;

    header[i++] = 0x82;

    if (len < 126) {
        header[i++] = len;
    } else if (len < 65536) {
        header[i++] = 126;
        header[i++] = (len >> 8) & 0xFF;
        header[i++] = len & 0xFF;
        header_len += 2;
    } else {
        header[i++] = 127;
        header[i++] = 0;
        header[i++] = 0;
        header[i++] = 0;
        header[i++] = 0;
        header[i++] = (len >> 24) & 0xFF;
        header[i++] = (len >> 16) & 0xFF;
        header[i++] = (len >> 8) & 0xFF;
        header[i++] = len & 0xFF;
        header_len += 8;
    }

    ssize_t sent = send(ws->socket_fd, header, header_len, 0);
    if (sent < 0) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Send failed: %s", strerror(errno));
        ws->connected = false;
        return -1;
    }

    sent = send(ws->socket_fd, data, len, 0);
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

    struct pollfd pfd = {.fd = ws->socket_fd, .events = POLLIN};

    int ret = poll(&pfd, 1, timeout_ms);
    if (ret < 0) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Poll failed: %s", strerror(errno));
        return -1;
    }
    if (ret == 0) {
        return 0;
    }

    uint8_t header[14];
    ssize_t received = recv(ws->socket_fd, header, 2, 0);
    if (received <= 0) {
        if (received == 0) {
            snprintf(ws->error_msg, sizeof(ws->error_msg), "Connection closed");
        } else {
            snprintf(ws->error_msg, sizeof(ws->error_msg), "Receive failed: %s", strerror(errno));
        }
        *data = NULL;
        ws->connected = false;
        return -1;
    }

    uint8_t opcode = header[0] & 0x0F;
    bool masked = (header[1] & 0x80) != 0;
    uint64_t payload_len = header[1] & 0x7F;

    if (payload_len == 126) {
        received = recv(ws->socket_fd, header + 2, 2, MSG_WAITALL);
        if (received != 2) {
            snprintf(ws->error_msg, sizeof(ws->error_msg), "Incomplete length");
            return -1;
        }
        payload_len = (header[2] << 8) | header[3];
    } else if (payload_len == 127) {
        received = recv(ws->socket_fd, header + 2, 8, MSG_WAITALL);
        if (received != 8) {
            snprintf(ws->error_msg, sizeof(ws->error_msg), "Incomplete length");
            return -1;
        }
        payload_len = ((uint64_t)header[2] << 56) |
                      ((uint64_t)header[3] << 48) |
                      ((uint64_t)header[4] << 40) |
                      ((uint64_t)header[5] << 32) |
                      ((uint64_t)header[6] << 24) |
                      ((uint64_t)header[7] << 16) |
                      ((uint64_t)header[8] << 8) |
                      ((uint64_t)header[9]);
    }

    if (opcode == 0x08) {
        ws_disconnect(ws);
        return -1;
    }
    if (opcode == 0x09) {
        uint8_t pong[2] = {0x8A, 0x00};
        send(ws->socket_fd, pong, 2, 0);
        return ws_recv_binary(ws, data, timeout_ms);
    }
    if (opcode == 0x0A) {
        return ws_recv_binary(ws, data, timeout_ms);
    }

    if (payload_len > WS_MAX_FRAME_SIZE) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Frame too large");
        return -1;
    }

    *data = malloc(payload_len);
    if (!*data) {
        snprintf(ws->error_msg, sizeof(ws->error_msg), "Memory allocation failed");
        return -1;
    }

    received = 0;
    while (received < (ssize_t)payload_len) {
        ssize_t r = recv(ws->socket_fd, *data + received, payload_len - received, MSG_WAITALL);
        if (r <= 0) {
            snprintf(ws->error_msg, sizeof(ws->error_msg), "Connection closed during receive");
            free(*data);
            *data = NULL;
            ws->connected = false;
            return -1;
        }
        received += r;
    }

    if (masked) {
        uint8_t mask[4];
        recv(ws->socket_fd, mask, 4, MSG_WAITALL);
        for (uint64_t i = 0; i < payload_len; i++) {
            (*data)[i] ^= mask[i % 4];
        }
    }

    return (ssize_t)payload_len;
}

int ws_send_text(BBWebSocket* ws, const char* text) {
    return ws_send_binary(ws, (const uint8_t*)text, strlen(text));
}

ssize_t ws_recv_text(BBWebSocket* ws, char** text, int timeout_ms) {
    uint8_t* data = NULL;
    ssize_t len = ws_recv_binary(ws, &data, timeout_ms);

    if (len > 0) {
        *text = (char*)data;
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

#endif  // USE_LIBWEBSOCKETS
