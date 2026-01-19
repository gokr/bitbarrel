#ifndef BITBARREL_INTERNAL_H
#define BITBARREL_INTERNAL_H

#define _GNU_SOURCE

#include "../include/bitbarrel.h"
#include "websocket.h"
#include <pthread.h>

// Internal structure of BBClient
struct BitBarrelClient {
    BBWebSocket* ws;
    uint32_t next_seq;
    BBConfig config;
    char* current_barrel;
    bool closing;

    // PubSub state
    BBMessageCallback message_callback;
    void* callback_userdata;
    pthread_mutex_t callback_lock;

    // Error state
    char last_error[512];
    pthread_mutex_t error_lock;
    pthread_mutex_t request_lock;
};

#endif // BITBARREL_INTERNAL_H
