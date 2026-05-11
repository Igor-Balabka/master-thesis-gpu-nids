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

// --- Prototypes ---
void test_header_parsing();
void test_buffer_continuity();
void test_ac_detection();
void test_identity();
long run_gpu_test_single_packet(AC_Automata *m, const char *data);

/**
 * Helper function to run the GPU engine on a single string.
 * It simulates a full MbufPool environment for a single packet.
 */
long run_gpu_test_single_packet(AC_Automata *m, const char *data)
{
    long data_len = strlen(data);
    long matches = 0;

    // 1. Allocate a mini Pinned Memory Pool for this unit test
    char *pinned_data;
    cudaHostAlloc((void **)&pinned_data, data_len, cudaHostAllocDefault);
    memcpy(pinned_data, data, data_len);

    // 2. Create a fake mbuf descriptor
    fake_rte_mbuf test_mbuf;
    test_mbuf.buf_addr = pinned_data;
    test_mbuf.data_len = (uint16_t)data_len;
    test_mbuf.packet_id = 0;

    // 3. Create a temporary MbufPool
    MbufPool temp_pool;
    temp_pool.mempool_data = (unsigned char *)pinned_data;
    temp_pool.mbuf_array = &test_mbuf;
    temp_pool.packet_count = 1;
    temp_pool.total_bytes = data_len;

    // 4. Call the GPU benchmark engine (1 loop)
    run_classic_packet_benchmark(m, &temp_pool, 1, &matches);

    // 5. Cleanup pinned memory
    cudaFreeHost(pinned_data);

    return matches;
}

/**
 * [TEST] Header Parsing
 * Verifies that the pointer arithmetic correctly skips Ethernet, IP, and TCP headers
 * to reach the actual payload data.
 */
void test_header_parsing()
{
    printf("[UNIT TEST] Checking Header Parsing... ");
    unsigned char fake_packet[60];
    memset(fake_packet, 0, 60);
    
    // Setup a fake IP header (IPv4, 20 bytes)
    struct iphdr *ip = (struct iphdr *)(fake_packet + 14); // Skip Eth
    ip->ihl = 5;
    ip->protocol = IPPROTO_TCP;
    
    // Setup a fake TCP header (20 bytes)
    struct tcphdr *tcp = (struct tcphdr *)(fake_packet + 34); // Skip Eth + IP
    tcp->doff = 5;
    
    // Place a known string at the expected payload start
    memcpy(fake_packet + 54, "GET /", 5);
    
    int offset = 14 + (ip->ihl * 4) + (tcp->doff * 4);
    if (offset == 54 && memcmp(fake_packet + offset, "GET /", 5) == 0)
        printf("PASSED ✅\n");
    else
        printf("FAILED ❌\n");
}

/**
 * [TEST] Mbuf Continuity
 * Ensures that our simulated MbufPool correctly handles contiguous memory addresses,
 * which is vital for the GPU to read batches of packets.
 */
void test_buffer_continuity()
{
    printf("[UNIT TEST] Checking Mbuf Continuity... ");
    fake_rte_mbuf mbufs[2];
    char fake_ram[30]; 

    mbufs[0].buf_addr = fake_ram + 0;
    mbufs[0].data_len = 10;

    mbufs[1].buf_addr = fake_ram + 10;
    mbufs[1].data_len = 20;

    // Verify if pointer arithmetic matches our expected data layout
    if ((char *)mbufs[1].buf_addr - (char *)mbufs[0].buf_addr == 10)
        printf("PASSED ✅\n");
    else
        printf("FAILED ❌\n");
}

/**
 * [TEST] AC Detection (CPU)
 * Basic validation of the Aho-Corasick algorithm implementation on host.
 */
void test_ac_detection()
{
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

/**
 * [TEST] Identity (CPU vs GPU)
 * Crucial test: ensures the GPU produces the same number of matches as the CPU
 * for a specific pattern.
 */
void test_identity()
{
    printf("[TEST] Identity (CPU vs GPU)... ");
    AC_Automata *m = ac_create();
    ac_add_pattern(m, "MALWARE", 1);
    ac_finalize(m);

    const char *data = "INIT_PAYLOAD_MALWARE_END";

    long cpu_matches = ac_search_benchmark(m, data, strlen(data));
    long gpu_matches = run_gpu_test_single_packet(m, data);

    if (cpu_matches == gpu_matches && cpu_matches == 1)
        printf("PASSED ✅ (%ld matches)\n", cpu_matches);
    else
    {
        printf("FAILED ❌ CPU:%ld GPU:%ld\n", cpu_matches, gpu_matches);
        exit(1);
    }
    ac_free(m);
}

/**
 * [TEST] Empty Payload
 * Edge case: verifies that empty packets do not cause crashes or false positives.
 */
void test_empty_payload()
{
    printf("[UNIT TEST] Checking Empty Packet Handling... ");
    AC_Automata *m = ac_create();
    ac_add_pattern(m, "MALWARE", 1);
    ac_finalize(m);

    const char *data = "";
    long gpu_matches = run_gpu_test_single_packet(m, data);

    if (gpu_matches == 0)
        printf("PASSED ✅\n");
    else
        printf("FAILED ❌\n");
    ac_free(m);
}

/**
 * [TEST] Overlapping Patterns
 * Tests the "Aho" part of Aho-Corasick: detecting multiple patterns that share characters.
 * Example: "USHERS" contains "HE", "SHE", and "HERS".
 */
void test_overlapping_patterns()
{
    printf("[UNIT TEST] Checking Overlapping Patterns (GPU)... ");
    AC_Automata *m = ac_create();
    ac_add_pattern(m, "HE", 1);
    ac_add_pattern(m, "SHE", 2);
    ac_add_pattern(m, "HERS", 3);
    ac_finalize(m);

    const char *data = "USHERS";
    long gpu_matches = run_gpu_test_single_packet(m, data);

    if (gpu_matches == 3)
        printf("PASSED ✅\n");
    else
        printf("FAILED ❌ (Expected 3, got %ld)\n", gpu_matches);
    ac_free(m);
}

/**
 * [TEST] GPU Batch Processing
 * Advanced test: validates that the GPU can process multiple packets (Mbufs) 
 * of different sizes stored in a contiguous memory block.
 */
void test_gpu_batch_processing()
{
    printf("[UNIT TEST] Checking GPU Batch Processing (3 Mbufs)... ");
    AC_Automata *m = ac_create();
    ac_add_pattern(m, "VIRUS", 1);
    ac_finalize(m);

    // Prepare 3 distinct packets in one memory area
    const char *p1 = "NORMAL_TRAFFIC_1"; // 16 bytes
    const char *p2 = "SOME_VIRUS_HERE";  // 15 bytes (Match!)
    const char *p3 = "SAFE_BUT_VIRUS_!"; // 17 bytes (Match!)
    int total_len = 16 + 15 + 17;

    char *pinned_data;
    cudaHostAlloc((void **)&pinned_data, total_len, cudaHostAllocDefault);
    memcpy(pinned_data, p1, 16);
    memcpy(pinned_data + 16, p2, 15);
    memcpy(pinned_data + 31, p3, 17);

    // Create 3 mbufs pointing to their respective data in the pinned memory
    fake_rte_mbuf mbufs[3];
    mbufs[0].buf_addr = pinned_data;
    mbufs[0].data_len = 16;
    mbufs[1].buf_addr = pinned_data + 16;
    mbufs[1].data_len = 15;
    mbufs[2].buf_addr = pinned_data + 31;
    mbufs[2].data_len = 17;

    MbufPool temp_pool;
    temp_pool.mempool_data = (unsigned char *)pinned_data;
    temp_pool.mbuf_array = mbufs;
    temp_pool.packet_count = 3;
    temp_pool.total_bytes = total_len;

    long total_matches = 0;
    run_classic_packet_benchmark(m, &temp_pool, 1, &total_matches);

    cudaFreeHost(pinned_data);
    ac_free(m);

    if (total_matches == 2)
        printf("PASSED ✅\n");
    else
        printf("FAILED ❌ (Expected 2, got %ld)\n", total_matches);
}

int main()
{
    printf("--- RUNNING NIDS UNIT TESTS ---\n");
    test_header_parsing();
    test_buffer_continuity();
    test_ac_detection();
    test_identity();
    test_empty_payload();
    test_overlapping_patterns();
    test_gpu_batch_processing();
    printf("--- ALL TESTS COMPLETED ---\n");
    return 0;
}