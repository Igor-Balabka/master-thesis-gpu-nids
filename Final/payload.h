#ifndef PAYLOAD_H
#define PAYLOAD_H

#include <pcap.h>
#include <stddef.h>

typedef struct {
    long offset; 
    int length;
} PacketData;

int packetMemoryManager(pcap_t *handle, char *all_payloads, PacketData *meta, int max_packets, size_t max_buffer_size);

void freePacketMemory(char *all_payloads, PacketData *meta);

#endif