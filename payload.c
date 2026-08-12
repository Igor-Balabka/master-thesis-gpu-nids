#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <cuda_runtime.h>
#include "payload.h"

// Load a PCAP file into a custom mbuf pool using pinned host memory
MbufPool *load_pcap_to_mbuf_pool(const char *filename) {
    printf("--- Opening Pcap File: %s ---\n", filename);
    char errbuf[PCAP_ERRBUF_SIZE];
    pcap_t *open_file = pcap_open_offline(filename, errbuf);

    if (open_file == NULL) {
        printf("Error: Impossible to open file: %s\n", errbuf);
        return NULL;
    }

    struct pcap_pkthdr *header;
    const u_char *packet;
    size_t total_bytes = 0;
    unsigned int count = 0;

    // First pass: count packets and calculate total payload bytes needed
    while (pcap_next_ex(open_file, &header, &packet) == 1) {
        total_bytes += header->caplen;
        count++;
    }

    // Allocate memory for the pool structure and packet array
    MbufPool *pool = (MbufPool *)malloc(sizeof(MbufPool));
    pool->packet_count = count;
    pool->total_bytes = total_bytes;
    pool->mbuf_array = (fake_rte_mbuf *)malloc(count * sizeof(fake_rte_mbuf));

    // Allocate CUDA pinned memory on host for fast GPU transfers
    cudaError_t err = cudaHostAlloc((void **)&pool->mempool_data, total_bytes, cudaHostAllocDefault);
    if (err != cudaSuccess) {
        printf("Error allocating Pinned Memory: %s\n", cudaGetErrorString(err));
        free(pool->mbuf_array);
        free(pool);
        pcap_close(open_file);
        return NULL;
    }

    // Close and reopen the file for the second pass
    pcap_close(open_file);
    open_file = pcap_open_offline(filename, errbuf);

    size_t curr_offset = 0;
    unsigned int valid_packets = 0;

    // Second pass: parse packets, extract payload, and fill the pool
    while (pcap_next_ex(open_file, &header, &packet) == 1) {
        struct ip *ip_header = (struct ip *)(packet + 14);
        if (ip_header->ip_v != 4) continue; // Keep only IPv4 packets

        int ip_header_len = ip_header->ip_hl * 4;
        const u_char *payload = NULL;
        int payload_len = 0;
        uint16_t src_p = 0, dst_p = 0;

        // Parse TCP or UDP layers to get ports and payload location
        if (ip_header->ip_p == IPPROTO_TCP) {
            struct tcphdr *tcp_header = (struct tcphdr *)(packet + 14 + ip_header_len);
            src_p = ntohs(tcp_header->source);
            dst_p = ntohs(tcp_header->dest);
            payload = packet + 14 + ip_header_len + (tcp_header->doff * 4);
        } else if (ip_header->ip_p == IPPROTO_UDP) {
            struct udphdr *udp_header = (struct udphdr *)(packet + 14 + ip_header_len);
            src_p = ntohs(udp_header->source);
            dst_p = ntohs(udp_header->dest);
            payload = packet + 14 + ip_header_len + 8;
        } else {
            continue; // Skip non-TCP/UDP packets
        }

        payload_len = header->caplen - (payload - packet);
        if (payload_len <= 0) continue;

        // Copy payload data into pinned memory buffer
        memcpy(pool->mempool_data + curr_offset, payload, payload_len);

        // Fill metadata for the current packet
        fake_rte_mbuf *mbuf = &pool->mbuf_array[valid_packets];
        mbuf->buf_addr = pool->mempool_data + curr_offset;
        mbuf->data_len = (uint16_t)payload_len;
        mbuf->packet_id = valid_packets;
        mbuf->src_ip = ip_header->ip_src.s_addr;
        mbuf->dst_ip = ip_header->ip_dst.s_addr;
        mbuf->src_port = src_p;
        mbuf->dst_port = dst_p;
        mbuf->proto = ip_header->ip_p;

        curr_offset += payload_len;
        valid_packets++;
    }

    pool->packet_count = valid_packets;
    pool->total_bytes = curr_offset;

    pcap_close(open_file);
    printf("Mbuf Pool ready: %u valid packets, %zu bytes stored in Pinned Memory.\n", valid_packets, curr_offset);

    return pool;
}

// Free all resources allocated for the mbuf pool
void free_mbuf_pool(MbufPool *pool) {
    if (pool) {
        if (pool->mempool_data) {
            cudaFreeHost(pool->mempool_data); // Free CUDA pinned memory
        }
        if (pool->mbuf_array) {
            free(pool->mbuf_array); // Free packet metadata array
        }
        free(pool); // Free main structure
    }
}