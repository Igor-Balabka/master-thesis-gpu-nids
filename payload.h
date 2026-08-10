//Strccture MbufPool for tests#ifndef PAYLOAD_H
#ifndef PAYLOAD_H
#define PAYLOAD_H

#include <pcap.h>
#include <stdint.h>

typedef struct {
    void *buf_addr;
    uint16_t data_len;
    uint32_t packet_id;
    uint32_t src_ip;
    uint32_t dst_ip;
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t proto;
} fake_rte_mbuf;

typedef struct {
    unsigned char *mempool_data;
    fake_rte_mbuf *mbuf_array;
    unsigned int packet_count;
    size_t total_bytes;
} MbufPool;

MbufPool *load_pcap_to_mbuf_pool(const char *filename);
void free_mbuf_pool(MbufPool *pool);

#endif // PAYLOAD_H