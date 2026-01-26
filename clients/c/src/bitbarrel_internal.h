#ifndef BITBARREL_INTERNAL_H
#define BITBARREL_INTERNAL_H

#define _GNU_SOURCE

#include "../include/bitbarrel.h"
#include "websocket.h"
#include <pthread.h>
#include <sys/types.h>

// Server information from handshake
typedef struct {
    uint8_t version_major;
    uint8_t version_minor;
    char* server_id;
    char** plugins;
    size_t plugin_count;
} ServerInfo;

// Internal structure of BBClient
struct BitBarrelClient {
    BBWebSocket* ws;
    uint32_t next_seq;
    BBConfig config;
    char* current_barrel;
    bool closing;

    // Server handshake info
    ServerInfo server_info;
    bool handshake_received;

    // PubSub state
    BBMessageCallback message_callback;
    void* callback_userdata;
    pthread_mutex_t callback_lock;

    // Error state
    char last_error[512];
    pthread_mutex_t error_lock;
    pthread_mutex_t request_lock;
};

// Buffered event structure for pub/sub events
typedef struct BufferedEvent {
    char* topic;
    char* data;
    struct BufferedEvent* next;
} BufferedEvent;

// Pub/Sub internal functions
void queue_message(BBMessage* msg);
BBMessage* dequeue_message(void);
BBResult process_pubsub_event(BBClient* client, const uint8_t* buffer, size_t len);
BBResult recv_response_and_buffer_events(BBClient* client, uint8_t** response_data,
                                         ssize_t* response_len, BufferedEvent** events);
void process_buffered_events(BBClient* client, BufferedEvent* events);
void free_buffered_events(BufferedEvent* events);

#endif // BITBARREL_INTERNAL_H
