#include "payload.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cuda_runtime.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <netinet/if_ether.h>
#include <arpa/inet.h>

int packetMemoryManager(pcap_t *handle, char *all_payloads, PacketData *meta, int max_packets, size_t max_buffer_size) {
    struct pcap_pkthdr *header;
    const u_char *packet;

    int count = 0;
    long current_offset = 0; 

    while (count < max_packets && pcap_next_ex(handle, &header, &packet) >= 0) {
        struct ethhdr *eth = (struct ethhdr *)packet;

        if (ntohs(eth->h_proto) != ETH_P_IP) continue;

        struct iphdr *ip = (struct iphdr *)(packet + sizeof(struct ethhdr));
        int ip_header_len = ip->ihl * 4;
        int payload_offset = 0;

        if (ip->protocol == IPPROTO_TCP) {
            struct tcphdr *tcp = (struct tcphdr *)(packet + sizeof(struct ethhdr) + ip_header_len);
            payload_offset = sizeof(struct ethhdr) + ip_header_len + (tcp->doff * 4);
        } 
        else if (ip->protocol == IPPROTO_UDP) {
            payload_offset = sizeof(struct ethhdr) + ip_header_len + sizeof(struct udphdr);
        } 
        else continue; 

        int p_len = header->caplen - payload_offset;

        if (current_offset + p_len >= max_buffer_size) break;

        if (p_len > 0) {
            meta[count].offset = current_offset;
            meta[count].length = p_len;
            
            memcpy(all_payloads + current_offset, packet + payload_offset, p_len);

            current_offset += p_len;
            count++;
        }
    }
    return count;
} 

void freePacketMemory(char *all_payloads, PacketData *meta) {
    if (all_payloads) cudaFreeHost(all_payloads);
    if (meta) cudaFreeHost(meta);
}