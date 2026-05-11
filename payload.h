#ifndef PAYLOAD_H
#define PAYLOAD_H

#include <pcap.h>
#include <stdint.h>

/**
 * fake_rte_mbuf: Mimics the DPDK 'rte_mbuf' structure.
 * This contains pointers to the raw payload and network metadata.
 * Using a small descriptor like this allows for efficient packet management
 * without moving the actual data in memory.
 */
typedef struct
{
    void *buf_addr;     // pointer for the ram payload
    uint16_t data_len;  // payload length (excluding the header)
    uint32_t packet_id; // unique packet id

    uint32_t src_ip;   // IP Source
    uint32_t dst_ip;   // IP Destination
    uint16_t src_port; // Port Source
    uint16_t dst_port; // Port Destination
    uint8_t proto;     // Protocole (6 fort TCP, 17 fort UDP)
} fake_rte_mbuf;

/**
 * MbufPool: Manages a large contiguous memory block.
 * This structure simulates a DPDK Mempool. By storing all payloads in a
 * single 'mempool_data' block allocated via cudaHostAlloc, we ensure
 * maximum DMA (Direct Memory Access) performance for GPU transfers.
 */
typedef struct
{
    unsigned char *mempool_data; // Pointer to the large Pinned Memory block (cudaHostAlloc)
    fake_rte_mbuf *mbuf_array;   // Array of descriptors (mbufs) pointing into the data block
    unsigned int packet_count;   // Total number of valid packets stored
    size_t total_bytes;          // Total size in bytes of the mempool_data
} MbufPool;

/**
 * load_pcap_to_mbuf_pool:
 * Parses a PCAP file, extracts payloads, and fills the MbufPool.
 * All memory is allocated in a GPU-friendly way (Pinned Memory).
 */
MbufPool *load_pcap_to_mbuf_pool(const char *filename);

/**
 * free_mbuf_pool:
 * Releases all resources associated with the pool,
 * including the descriptors and the pinned data block.
 */
void free_pcap_store(MbufPool *pool);

#endif