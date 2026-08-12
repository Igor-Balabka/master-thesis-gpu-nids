// Structure MbufPool for tests and in-memory benchmarks
#ifndef PAYLOAD_H
#define PAYLOAD_H

#include <pcap.h>
#include <stdint.h>

// Custom structure mimicking DPDK mbuf to store packet metadata and info
typedef struct {
    void *buf_addr;       // Pointer to the actual packet payload in memory
    uint16_t data_len;    // Length of the packet payload
    uint32_t packet_id;   // Index or ID of the packet
    uint32_t src_ip;      // Source IPv4 address
    uint32_t dst_ip;      // Destination IPv4 address
    uint16_t src_port;    // Source port (TCP/UDP)
    uint16_t dst_port;    // Destination port (TCP/UDP)
    uint8_t proto;        // Protocol type (e.g. TCP or UDP)
} fake_rte_mbuf;

// Structure representing a pool of pre-loaded packets in RAM
typedef struct {
    unsigned char *mempool_data; // Continuous buffer storing all raw packet payloads
    fake_rte_mbuf *mbuf_array;   // Array of metadata for each packet
    unsigned int packet_count;   // Total number of valid packets loaded
    size_t total_bytes;          // Total size of payloads in bytes
} MbufPool;

// Function to read a PCAP file and load packets into a MbufPool
MbufPool *load_pcap_to_mbuf_pool(const char *filename);

// Function to free all memory allocated for the MbufPool
void free_mbuf_pool(MbufPool *pool);

#endif // PAYLOAD_H