#ifndef PAYLOAD_H
#define PAYLOAD_H

#include <pcap.h>

typedef struct {
    unsigned char *raw_data;     // Pointer 1: All packet data
    size_t *offsets;             // Pointer 2: Start position of each packet
    unsigned int *sizes;         // Pointer 3: Size of each packet
    unsigned int packet_count;
    size_t total_bytes;
} PcapDataStore;


PcapDataStore* load_pcap_to_memory(const char *filename);


void free_pcap_store(PcapDataStore *pcapFile);

#endif