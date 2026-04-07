#ifndef PAYLOAD_H
#define PAYLOAD_H

#include <pcap.h>

typedef struct {
    size_t offset;
    unsigned int length;
} PacketData;

typedef struct {
    unsigned char *raw_data;     // Pointer 1: All payloads data
    size_t *offsets;             // Pointer 2: Start position of each packet
    unsigned int *sizes;         // Pointer 3: Size of each packet
    PacketData *meta;
    unsigned int packet_count;
    size_t total_bytes;
} PcapDataStore;


PcapDataStore* load_pcap_to_memory(const char *filename);


void free_pcap_store(PcapDataStore *pcapFile);

int packetMemoryManager(pcap_t *handle, char *payload, PacketData *meta, int max_pkts, size_t max_bytes);

#endif