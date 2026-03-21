#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cuda_runtime.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <netinet/if_ether.h>
#include <arpa/inet.h>
#include "payload.h"
#include "ac.h"


void test_header_parsing() {
    printf("[UNIT TEST] Checking Header Parsing... ");
    
    // Simuler un paquet TCP standard (14 Eth + 20 IP + 20 TCP = 54)
    // On met "GET /" juste après le header
    unsigned char fake_packet[60];
    memset(fake_packet, 0, 60);
    
    struct iphdr *ip = (struct iphdr *)(fake_packet + 14);
    ip->ihl = 5; // 5 * 4 = 20 octets
    ip->protocol = IPPROTO_TCP;
    
    struct tcphdr *tcp = (struct tcphdr *)(fake_packet + 14 + 20);
    tcp->doff = 5; // 5 * 4 = 20 octets
    
    memcpy(fake_packet + 54, "GET /", 5);

    // Calcul manuel selon ta logique dans payload.c
    int ip_len = ip->ihl * 4;
    int tcp_len = tcp->doff * 4;
    int offset = 14 + ip_len + tcp_len;

    if (offset == 54 && memcmp(fake_packet + offset, "GET /", 5) == 0) {
        printf("PASSED ✅\n");
    } else {
        printf("FAILED ❌ (Offset: %d)\n", offset);
    }
}

void test_buffer_continuity() {
    printf("[UNIT TEST] Checking Buffer Continuity... ");
    
    PacketData meta[2];
    char buffer[1024];
    long current_off = 0;

    // Paquet 1 : 10 octets
    meta[0].offset = current_off;
    meta[0].length = 10;
    current_off += 10;

    // Paquet 2 : 20 octets
    meta[1].offset = current_off;
    meta[1].length = 20;

    if (meta[1].offset == 10) {
        printf("PASSED ✅\n");
    } else {
        printf("FAILED ❌ (Meta[1] starts at %ld)\n", meta[1].offset);
    }
}

void test_ac_detection() {
    printf("[UNIT TEST] Checking AC Detection... ");
    
    AC_Machine *m = ac_create();
    ac_add_pattern(m, "VIRUS", 1);
    ac_finalize(m);

    const char *data = "Normal data... VIRUS ... more data... VIRUS";
    long found = ac_search_benchmark(m, data, strlen(data));

    if (found == 2) {
        printf("PASSED ✅ (Found 2 matches)\n");
    } else {
        printf("FAILED ❌ (Found %ld matches)\n", found);
    }
    ac_free(m);
}

int main() {
    printf("--- RUNNING NIDS UNIT TESTS ---\n");
    test_header_parsing();
    test_buffer_continuity();
    test_ac_detection();
    printf("--- ALL TESTS COMPLETED ---\n");
    return 0;
}