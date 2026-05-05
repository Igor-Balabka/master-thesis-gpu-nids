#ifndef PAYLOAD_H
#define PAYLOAD_H

#include <pcap.h>
#include <stdint.h>

typedef struct {
    void *buf_addr;       // pointer for the ram payload
    uint16_t data_len;    // payload length
    uint32_t packet_id;   // packet id

    uint32_t src_ip;      // IP Source
    uint32_t dst_ip;      // IP Destination
    uint16_t src_port;    // Port Source
    uint16_t dst_port;    // Port Destination
    uint8_t  proto;       // Protocole (6 pour TCP, 17 pour UDP)
    uint8_t  _pad[3];
} fake_rte_mbuf;



typedef struct {
    unsigned char *mempool_data; // Le pointeur vers le gros bloc cudaHostAlloc
    fake_rte_mbuf *mbuf_array;   // Le tableau contenant tous tes mbufs
    unsigned int packet_count;   // Nombre total de paquets
    size_t total_bytes;          // Poids total pour le malloc
} MbufPool;

MbufPool* load_pcap_to_mbuf_pool(const char *filename);


void free_pcap_store(MbufPool *pool);

#endif