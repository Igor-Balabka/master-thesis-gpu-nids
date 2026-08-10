#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <netinet/if_ether.h>
#include <arpa/inet.h>
#include <cuda_runtime.h>

#include "config.h"
#include "payload.h"
#include "ac.h"
#include "gpu_engine.h"

// Definition des variables globales requises par dpdk.o pour les tests unitaires
volatile int stop_program = 0;
volatile int pcap_file_done = 0;

long run_gpu_test_single_packet(AC_Automata *m, const char *data) {
    long data_len = strlen(data);
    long matches = 0;

    char *pinned_data;
    cudaHostAlloc((void **)&pinned_data, data_len, cudaHostAllocDefault);
    memcpy(pinned_data, data, data_len);

    fake_rte_mbuf test_mbuf;
    test_mbuf.buf_addr = pinned_data;
    test_mbuf.data_len = (uint16_t)data_len;
    test_mbuf.packet_id = 0;

    MbufPool temp_pool;
    temp_pool.mempool_data = (unsigned char *)pinned_data;
    temp_pool.mbuf_array = &test_mbuf;
    temp_pool.packet_count = 1;
    temp_pool.total_bytes = data_len;

    run_classic_packet_benchmark(m, &temp_pool, 1, &matches);
    cudaFreeHost(pinned_data);
    return matches;
}

void test_header_parsing(void) {
    printf("[UNIT TEST] Checking Header Parsing... ");
    unsigned char fake_packet[60];
    memset(fake_packet, 0, 60);
    
    struct iphdr *ip = (struct iphdr *)(fake_packet + 14);
    ip->ihl = 5;
    ip->protocol = IPPROTO_TCP;
    
    struct tcphdr *tcp = (struct tcphdr *)(fake_packet + 34);
    tcp->doff = 5;
    
    memcpy(fake_packet + 54, "GET /", 5);
    
    int offset = 14 + (ip->ihl * 4) + (tcp->doff * 4);
    if (offset == 54 && memcmp(fake_packet + offset, "GET /", 5) == 0)
        printf("PASSED ✅\n");
    else
        printf("FAILED ❌\n");
}

void test_ac_detection(void) {
    printf("[UNIT TEST] Checking AC Detection (CPU)... ");
    AC_Automata *m = ac_create();
    ac_add_pattern(m, "VIRUS", 1);
    ac_finalize(m);
    
    const char *data = "Normal data... VIRUS ... VIRUS";
    long found = ac_search_benchmark(m, data, strlen(data));
    
    if (found == 2)
        printf("PASSED ✅\n");
    else
        printf("FAILED ❌\n");
    ac_free(m);
}

void test_identity(void) {
    printf("[TEST] Identity (CPU vs GPU)... ");
    AC_Automata *m = ac_create();
    ac_add_pattern(m, "MALWARE", 1);
    ac_finalize(m);

    const char *data = "INIT_PAYLOAD_MALWARE_END";

    long cpu_matches = ac_search_benchmark(m, data, strlen(data));
    long gpu_matches = run_gpu_test_single_packet(m, data);

    if (cpu_matches == gpu_matches && cpu_matches == 1)
        printf("PASSED ✅ (%ld matches)\n", cpu_matches);
    else {
        printf("FAILED ❌ CPU:%ld GPU:%ld\n", cpu_matches, gpu_matches);
        exit(1);
    }
    ac_free(m);
}

int main(void) {
    printf("--- RUNNING NIDS UNIT TESTS ---\n");
    test_header_parsing();
    test_ac_detection();
    test_identity();
    printf("--- ALL TESTS COMPLETED ---\n");
    return 0;
}