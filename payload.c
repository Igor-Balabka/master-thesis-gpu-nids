#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <netinet/in.h>
#include <netinet/if_ether.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <cuda_runtime.h> // Ajout pour cudaHostAlloc (Pinned Memory)
#include "payload.h"

MbufPool* load_pcap_to_mbuf_pool(const char *filename) {
    printf("--- Opening the Pcap File : %s\n", filename);
    char errbuf[PCAP_ERRBUF_SIZE];
    pcap_t* open_file = pcap_open_offline(filename, errbuf);
    
    if (open_file == NULL) {
        printf("❌ Impossible to open the file, wrong path: %s\n", errbuf);
        return NULL;
    }
    printf("✅ File opened correctly. Processing Data...\n");

    struct pcap_pkthdr *header;
    const u_char *packet;
    size_t total_bytes = 0;
    unsigned int count = 0;

    // --- Passe 1 : Compter le nombre de paquets et la taille maximale ---
    while (pcap_next_ex(open_file, &header, &packet) == 1) {
        total_bytes += header->caplen;
        count++;
    }

    // --- Allocation du Pool DPDK simulé ---
    MbufPool *pool = malloc(sizeof(MbufPool));
    pool->packet_count = count;
    pool->total_bytes = total_bytes;

    // 1. Allouer le tableau de mbufs
    pool->mbuf_array = malloc(count * sizeof(fake_rte_mbuf));

    // 2. Allouer le Memory Pool en "Pinned Memory" (Simule les Hugepages DPDK)
    cudaError_t err = cudaHostAlloc((void**)&pool->mempool_data, total_bytes, cudaHostAllocDefault);
    if (err != cudaSuccess) {
        printf("❌ Error allocating Pinned Memory: %s\n", cudaGetErrorString(err));
        return NULL;
    }

    pcap_close(open_file);
    open_file = pcap_open_offline(filename, errbuf);
    
    size_t curr_offset = 0;
    unsigned int valid_packets = 0;

    // --- Passe 2 : Extraction des Payloads et création des Mbufs ---
    while (pcap_next_ex(open_file, &header, &packet) == 1) {

        // Skip the headers (Ta logique d'origine, excellente)
        struct ip *ip_header = (struct ip *)(packet + 14);
        if (ip_header->ip_v != 4) continue;
        int ip_header_len = ip_header->ip_hl * 4; 
        int transport_header_len = 0;
        const u_char *payload = NULL;
        int payload_len = 0;
        uint16_t src_p = 0, dst_p = 0;

        if (ip_header->ip_p == IPPROTO_TCP) {
                struct tcphdr *tcp_header = (struct tcphdr *)(packet + 14 + ip_header_len);
                src_p = ntohs(tcp_header->source);
                dst_p = ntohs(tcp_header->dest);
                payload = packet + 14 + ip_header_len + (tcp_header->doff * 4);
            }
        else if (ip_header->ip_p == IPPROTO_UDP) {
                struct udphdr *udp_header = (struct udphdr *)(packet + 14 + ip_header_len);
                src_p = ntohs(udp_header->source);
                dst_p = ntohs(udp_header->dest);
                payload = packet + 14 + ip_header_len + 8; 
            }
        else {
            continue; 
        }
        
        payload_len = header->caplen - (payload - packet);
            if (payload_len <= 0) continue;

        // Copier le payload dans notre "Memory Pool" Pinned
        memcpy(pool->mempool_data + curr_offset, payload, payload_len);

        fake_rte_mbuf *mbuf = &pool->mbuf_array[valid_packets];

        mbuf->buf_addr   = pool->mempool_data + curr_offset;
        mbuf->data_len   = (uint16_t)payload_len;
        mbuf->packet_id  = valid_packets;
            
            // Ajout des métadonnées réseau
        mbuf->src_ip     = ip_header->ip_src.s_addr; // Déjà en network byte order
        mbuf->dst_ip     = ip_header->ip_dst.s_addr;
        mbuf->src_port   = src_p;
        mbuf->dst_port   = dst_p;
        mbuf->proto      = ip_header->ip_p;

            curr_offset += payload_len;
            valid_packets++;
    }

    // Mise à jour finale avec les vraies valeurs valides
    pool->packet_count = valid_packets;
    pool->total_bytes = curr_offset;

    pcap_close(open_file);
    printf("✅ DPDK Mbuf Pool ready : %u valid packets, %zu bytes stored in Pinned Memory.\n", valid_packets, curr_offset);
    
    return pool;
}

// Fonction de nettoyage propre
void free_mbuf_pool(MbufPool *pool) {
    if (pool) {
        if (pool->mempool_data) {
            cudaFreeHost(pool->mempool_data);
        }
        if (pool->mbuf_array) {
            free(pool->mbuf_array);
        }
        free(pool);
    }
}