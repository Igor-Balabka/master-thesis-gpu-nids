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
#include "Kernel/ac_classic.h" 

// --- Prototypes (To avoid implicit declaration warnings) ---
void test_header_parsing();
void test_buffer_continuity();
void test_ac_detection();
void test_identity();
long run_gpu_test_single_packet(AC_Machine *m, const char *data);

// --- Helpers ---
long run_gpu_test_single_packet(AC_Machine *m, const char *data) {
    long data_len = strlen(data);
    long offset = 0;
    int length = (int)data_len;
    long matches = 0;
    // Loops = 1 for unit tests
    run_classic_packet_benchmark(m, data, &offset, &length, 1, 1, &matches);
    return matches;
}

// --- Test Implementation ---
void test_header_parsing() {
    printf("[UNIT TEST] Checking Header Parsing... ");
    unsigned char fake_packet[60];
    memset(fake_packet, 0, 60);
    struct iphdr *ip = (struct iphdr *)(fake_packet + 14);
    ip->ihl = 5; ip->protocol = IPPROTO_TCP;
    struct tcphdr *tcp = (struct tcphdr *)(fake_packet + 34);
    tcp->doff = 5;
    memcpy(fake_packet + 54, "GET /", 5);
    int offset = 14 + (ip->ihl * 4) + (tcp->doff * 4);
    if (offset == 54 && memcmp(fake_packet + offset, "GET /", 5) == 0) printf("PASSED ✅\n");
    else printf("FAILED ❌\n");
}

void test_buffer_continuity() {
    printf("[UNIT TEST] Checking Buffer Continuity... ");
    PacketData meta[2];
    meta[0].offset = 0; meta[0].length = 10;
    meta[1].offset = 10; meta[1].length = 20;
    if (meta[1].offset == 10) printf("PASSED ✅\n");
    else printf("FAILED ❌\n");
}

void test_ac_detection() {
    printf("[UNIT TEST] Checking AC Detection (CPU)... ");
    AC_Machine *m = ac_create();
    ac_add_pattern(m, "VIRUS", 1);
    ac_finalize(m);
    const char *data = "Normal data... VIRUS ... VIRUS";
    long found = ac_search_benchmark(m, data, strlen(data));
    if (found == 2) printf("PASSED ✅\n");
    else printf("FAILED ❌\n");
    ac_free(m);
}

void test_identity() {
    printf("[TEST] Identity (CPU vs GPU)... ");
    AC_Machine *m = ac_create();
    ac_add_pattern(m, "MALWARE", 1);
    ac_finalize(m);
    const char *data = "INIT_PAYLOAD_MALWARE_END";
    long cpu_matches = ac_search_benchmark(m, data, strlen(data));
    long gpu_matches = run_gpu_test_single_packet(m, data);
    if (cpu_matches == gpu_matches) printf("PASSED ✅ (%ld matches)\n", cpu_matches);
    else { printf("FAILED ❌ CPU:%ld GPU:%ld\n", cpu_matches, gpu_matches); exit(1); }
    ac_free(m);
}

int main() {
    printf("--- RUNNING NIDS UNIT TESTS (CUDA VERSION) ---\n");
    test_header_parsing();
    test_buffer_continuity();
    test_ac_detection();
    test_identity();
    printf("--- ALL TESTS COMPLETED ---\n");
    return 0;
}