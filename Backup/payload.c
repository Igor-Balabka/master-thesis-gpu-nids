#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <netinet/in.h>
#include <netinet/if_ether.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include "payload.h"


PcapDataStore* load_pcap_to_memory(const char *filename){
    printf("--- Opening the Pcap File name %s : \n",filename);
    char errbuf[PCAP_ERRBUF_SIZE];
    pcap_t* open_file = pcap_open_offline(filename,errbuf);
    if(open_file == NULL){
        printf("impossible to open the file, wrong path \n");
        return NULL;
    }
    printf("file openend correctly : Processing Data \n");

struct pcap_pkthdr *header;
const u_char *packet;
size_t total_bytes = 0;
unsigned int count = 0;

while (pcap_next_ex(open_file, &header, &packet) == 1) {
    total_bytes += header->caplen;
    count++;
}

PcapDataStore *pcapData = malloc(sizeof(PcapDataStore));
pcapData->raw_data = malloc(total_bytes);
pcapData->offsets = malloc(count * sizeof(size_t));
pcapData->sizes = malloc(count * sizeof(unsigned int));
pcapData->packet_count = count;
pcapData->total_bytes = total_bytes;

pcap_close(open_file);
open_file = pcap_open_offline(filename,errbuf);
size_t curr_offset = 0;
unsigned int valid_packets= 0;
while (pcap_next_ex(open_file,&header,&packet)==1){

    //skip the header
    struct ip *ip_header = (struct ip *)(packet + 14);
    if (ip_header->ip_v != 4) continue;
    int ip_header_len = ip_header->ip_hl * 4; 
    int transport_header_len = 0;
    const u_char *payload = NULL;
    int payload_len = 0;

    if (ip_header->ip_p == IPPROTO_TCP) {
        struct tcphdr *tcp_header = (struct tcphdr *)(packet + 14 + ip_header_len);
        transport_header_len = tcp_header->doff * 4;
    } 
    else if (ip_header->ip_p == IPPROTO_UDP) {
        transport_header_len = 8; 
    } 
    else {
        continue; 
    }
    int total_headers_len = 14 + ip_header_len + transport_header_len;
    payload = packet + total_headers_len;
    payload_len = header->caplen - total_headers_len;
    if (payload_len <= 0) continue;


    //copy of the payload
    memcpy(pcapData->raw_data + curr_offset,payload,payload_len);
    pcapData->offsets[valid_packets] = curr_offset;
    pcapData->sizes[valid_packets] = header->caplen;
    curr_offset += payload_len;
    valid_packets++;
}

pcapData->packet_count = valid_packets;
pcapData->total_bytes = curr_offset;

pcap_close(open_file);
return pcapData;
}


void free_pcap_store(PcapDataStore *pcapData){
    if (pcapData){
        free(pcapData->raw_data);
        free(pcapData->offsets);
        free(pcapData->sizes);
        free(pcapData);
    }
}


int packetMemoryManager(pcap_t *handle, char *payload, PacketData *meta, int max_pkts, size_t max_bytes) {
    struct pcap_pkthdr *h;
    const u_char *pkt;
    int count = 0;
    size_t current_offset = 0;

    while (count < max_pkts && pcap_next_ex(handle, &h, &pkt) == 1) {
        if (current_offset + h->caplen > max_bytes) break;
        
        memcpy(payload + current_offset, pkt, h->caplen);
        meta[count].offset = current_offset;
        meta[count].length = h->caplen;
        
        current_offset += h->caplen;
        count++;
    }
    return count;
}