//Global type, data structures and constantes#ifndef CONFIG_H
#ifndef CONFIG_H
#define CONFIG_H

#include <stdint.h>
#include <stddef.h>

#define ALPHABET_SIZE 256
#define MAX_PKTS_PER_SLOT 8192
#define MAX_PAYLOAD_SIZE 1500
#define NUM_STREAMS 3 // Mode 3 Streams CUDA pour chevauchement parfait (H2D / Exec / D2H)

typedef struct PacketBatch {
    char packet_data[MAX_PKTS_PER_SLOT * MAX_PAYLOAD_SIZE];
    uint32_t lengths[MAX_PKTS_PER_SLOT];
    uint32_t num_pkts;
    volatile int in_use;
} PacketBatch;

#endif // CONFIG_H