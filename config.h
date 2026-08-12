// Global types, data structures, and constants
#ifndef CONFIG_H
#define CONFIG_H

#include <stdint.h>
#include <stddef.h>

// Constants configuration for the NIDS
#define ALPHABET_SIZE 256        // Standard ASCII alphabet size
#define MAX_PKTS_PER_SLOT 4096   // Max packets in a single batch
#define MAX_PAYLOAD_SIZE 1500    // Max bytes per packet (standard Ethernet MTU)
#define NUM_STREAMS 16           // Number of CUDA streams for async GPU processing

// Structure to hold a batch of packets shared between producer and consumers
typedef struct PacketBatch {
    char packet_data[MAX_PKTS_PER_SLOT * MAX_PAYLOAD_SIZE]; // Raw packet payloads stored contiguously
    uint32_t lengths[MAX_PKTS_PER_SLOT];                    // Actual size of each packet in the batch
    uint32_t num_pkts;                                      // Total number of packets currently in this batch
    volatile int in_use;                                    // Lock flag to check if the batch is being processed
} PacketBatch;

#endif // CONFIG_H