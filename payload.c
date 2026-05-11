#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <netinet/in.h>
#include <netinet/if_ether.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <cuda_runtime.h>
#include "payload.h"

/**
 * Loads a PCAP file and transforms it into a DPDK-like Mbuf Pool.
 * The payloads are extracted and stored in Pinned Memory
 * to maximize GPU transfer throughput.
 */
MbufPool *load_pcap_to_mbuf_pool(const char *filename)
{
    printf("--- Opening the Pcap File : %s\n", filename);
    char errbuf[PCAP_ERRBUF_SIZE];
    pcap_t *open_file = pcap_open_offline(filename, errbuf);

    if (open_file == NULL)
    {
        printf("❌ Impossible to open the file, wrong path: %s\n", errbuf);
        return NULL;
    }
    printf("✅ File opened correctly. Processing Data...\n");

    struct pcap_pkthdr *header;
    const u_char *packet;
    size_t total_bytes = 0;
    unsigned int count = 0;

    // --- Pass 1: Count packets and calculate total required memory ---
    while (pcap_next_ex(open_file, &header, &packet) == 1)
    {
        total_bytes += header->caplen;
        count++;
    }

    // Allocate the Pool structure
    MbufPool *pool = malloc(sizeof(MbufPool));
    pool->packet_count = count;
    pool->total_bytes = total_bytes;

    // 1. Allocate the array of mbuf descriptors
    pool->mbuf_array = malloc(count * sizeof(fake_rte_mbuf));

    // 2. Allocate the Memory Pool in "Pinned Memory"
    // This simulates DPDK Hugepages and allows high-speed DMA transfers to the GPU
    cudaError_t err = cudaHostAlloc((void **)&pool->mempool_data, total_bytes, cudaHostAllocDefault);
    if (err != cudaSuccess)
    {
        printf("❌ Error allocating Pinned Memory: %s\n", cudaGetErrorString(err));
        return NULL;
    }

    // Re-open the file to perform the actual extraction
    pcap_close(open_file);
    open_file = pcap_open_offline(filename, errbuf);

    size_t curr_offset = 0;
    unsigned int valid_packets = 0;

    // --- Pass 2: Extract Payloads and populate Mbufs ---
    while (pcap_next_ex(open_file, &header, &packet) == 1)
    {

        // Network Header Parsing (Ethernet -> IP -> TCP/UDP)
        struct ip *ip_header = (struct ip *)(packet + 14);
        if (ip_header->ip_v != 4)
            continue; // We only handle IPv4

        int ip_header_len = ip_header->ip_hl * 4;
        int transport_header_len = 0;
        const u_char *payload = NULL;
        int payload_len = 0;
        uint16_t src_p = 0, dst_p = 0;

        // Extract transport layer info
        if (ip_header->ip_p == IPPROTO_TCP)
        {
            struct tcphdr *tcp_header = (struct tcphdr *)(packet + 14 + ip_header_len);
            src_p = ntohs(tcp_header->source);
            dst_p = ntohs(tcp_header->dest);
            payload = packet + 14 + ip_header_len + (tcp_header->doff * 4);
        }
        else if (ip_header->ip_p == IPPROTO_UDP)
        {
            struct udphdr *udp_header = (struct udphdr *)(packet + 14 + ip_header_len);
            src_p = ntohs(udp_header->source);
            dst_p = ntohs(udp_header->dest);
            payload = packet + 14 + ip_header_len + 8;
        }
        else
        {
            continue; // Skip non-TCP/UDP packets
        }

        // Calculate actual payload length (ignoring headers)
        payload_len = header->caplen - (payload - packet);
        if (payload_len <= 0)
            continue;

        // Copy raw payload into our contiguous Pinned Memory Pool
        memcpy(pool->mempool_data + curr_offset, payload, payload_len);

        // Populate the fake_rte_mbuf descriptor
        fake_rte_mbuf *mbuf = &pool->mbuf_array[valid_packets];
        mbuf->buf_addr = pool->mempool_data + curr_offset;
        mbuf->data_len = (uint16_t)payload_len;
        mbuf->packet_id = valid_packets;

        // Store network metadata (IPs and Ports) for later filtering/logging
        mbuf->src_ip = ip_header->ip_src.s_addr;
        mbuf->dst_ip = ip_header->ip_dst.s_addr;
        mbuf->src_port = src_p;
        mbuf->dst_port = dst_p;
        mbuf->proto = ip_header->ip_p;

        curr_offset += payload_len;
        valid_packets++;
    }

    // Final update with actual processed counts
    pool->packet_count = valid_packets;
    pool->total_bytes = curr_offset;

    pcap_close(open_file);
    printf("✅ DPDK Mbuf Pool ready : %u valid packets, %zu bytes stored in Pinned Memory.\n", valid_packets, curr_offset);

    return pool;
}

/**
 * Properly releases the Mbuf Pool memory.
 * Uses cudaFreeHost for the pinned memory and standard free for the rest.
 */
void free_mbuf_pool(MbufPool *pool)
{
    if (pool)
    {
        if (pool->mempool_data)
        {
            cudaFreeHost(pool->mempool_data);
        }
        if (pool->mbuf_array)
        {
            free(pool->mbuf_array);
        }
        free(pool);
    }
}