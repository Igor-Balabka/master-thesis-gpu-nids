#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <pcap.h>
#include <cuda_runtime.h>
#include <sys/stat.h>

#include <netinet/ether.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>

extern "C" {
    #include "../../ac.h"
}

#define ALPHABET_SIZE 256
#define TEST_DURATION_PER_CONFIG 5.0 
#define MAX_PAYLOAD_SIZE 1500

// Struct to store benchmark results for each configuration test
typedef struct {
    double throughput_gbps;
    unsigned long long pcap_loops;
    unsigned long long matches_per_loop;
    unsigned long long total_matches;
} TestResult;

// Macro to check CUDA errors and exit if something fails
#define CUDA_CHECK(call) \
    do { \
        cudaError_t err = call; \
        if (err != cudaSuccess) { \
            fprintf(stderr, "CUDA Error at %s:%d - %s\n", __FILE__, __LINE__, cudaGetErrorString(err)); \
            exit(EXIT_FAILURE); \
        } \
    } while (0)

// CUDA kernel for Aho-Corasick pattern matching during grid search tuning
__global__ void aho_corasick_tuner_kernel(
    const char *d_flat_payloads,
    const size_t *d_offsets,
    const uint32_t *d_lens,
    uint32_t start_pkt,
    uint32_t num_packets,
    const int *d_trans,
    const int *d_out,
    unsigned long long *d_matches_out)
{
    // Calculate global thread ID
    uint32_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= num_packets) return;

    uint32_t pkt_idx = start_pkt + idx;
    uint32_t len = d_lens[pkt_idx];
    size_t offset = d_offsets[pkt_idx];
    const char *payload = d_flat_payloads + offset;

    int state = 0;
    unsigned long long local_matches = 0;

    // Run the automaton over the packet payload bytes
    for (uint32_t i = 0; i < len; i++) {
        unsigned char ch = (unsigned char)payload[i];
        state = d_trans[state * ALPHABET_SIZE + ch];
        local_matches += d_out[state];
    }

    // Atomically add matches to the global counter
    if (local_matches > 0) {
        atomicAdd(d_matches_out, local_matches);
    }
}

// Function to test a specific configuration (threads per block + batch size)
TestResult test_configuration(
    int threads_per_block, 
    uint32_t batch_size,
    const char *d_flat_payloads,
    const size_t *d_offsets,
    const uint32_t *d_lens,
    uint32_t total_packets,
    size_t total_pcap_bytes,
    const int *d_trans,
    const int *d_out,
    unsigned long long *d_matches)
{
    CUDA_CHECK(cudaMemset(d_matches, 0, sizeof(unsigned long long)));

    struct timespec t_start, t_now;
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    unsigned long long pcap_loops = 0;
    unsigned long long total_matches = 0;
    unsigned long long matches_first_loop = 0;
    double elapsed = 0.0;

    // Loop processing until the test duration for this config is reached
    while (1) {
        uint32_t processed_in_loop = 0;

        while (processed_in_loop < total_packets) {
            uint32_t pkts_to_process = (total_packets - processed_in_loop > batch_size) ? 
                                       batch_size : (total_packets - processed_in_loop);

            int blocks = (pkts_to_process + threads_per_block - 1) / threads_per_block;

            // Launch the tuner kernel
            aho_corasick_tuner_kernel<<<blocks, threads_per_block>>>(
                d_flat_payloads, d_offsets, d_lens, processed_in_loop, pkts_to_process, d_trans, d_out, d_matches
            );

            cudaError_t err = cudaGetLastError();
            if (err != cudaSuccess) {
                TestResult err_res = {0.0, 0, 0, 0};
                return err_res;
            }

            processed_in_loop += pkts_to_process;
        }

        CUDA_CHECK(cudaDeviceSynchronize());
        pcap_loops++;

        unsigned long long current_loop_matches = 0;
        CUDA_CHECK(cudaMemcpy(&current_loop_matches, d_matches, sizeof(unsigned long long), cudaMemcpyDeviceToHost));
        
        if (pcap_loops == 1) {
            matches_first_loop = current_loop_matches;
        }

        total_matches += current_loop_matches;
        CUDA_CHECK(cudaMemset(d_matches, 0, sizeof(unsigned long long)));

        clock_gettime(CLOCK_MONOTONIC, &t_now);
        elapsed = (t_now.tv_sec - t_start.tv_sec) + (t_now.tv_nsec - t_start.tv_nsec) / 1e9;

        if (elapsed >= TEST_DURATION_PER_CONFIG) {
            break;
        }
    }

    // Calculate throughput in Gbps
    double total_bytes = (double)pcap_loops * total_pcap_bytes;
    double throughput_gbps = (total_bytes * 8.0) / (elapsed * 1e9);

    TestResult res;
    res.throughput_gbps = throughput_gbps;
    res.pcap_loops = pcap_loops;
    res.matches_per_loop = matches_first_loop;
    res.total_matches = total_matches;
    return res;
}

int main(int argc, char **argv) {
    const char *pcap_path = "/dev/shm/MixFile.pcap";
    const char *rules_path = "../../Rules/patterns.txt";

    if (argc > 1) pcap_path = argv[1];
    if (argc > 2) rules_path = argv[2];

    // Create directories to save CSV results
    mkdir("csv_results", 0777);
    mkdir("csv_results/GPU_in_memory", 0777);

    const char *csv_path = "csv_results/GPU_in_memory/grid_search_results.csv";
    FILE *csv_file = fopen(csv_path, "w");
    if (!csv_file) {
        fprintf(stderr, "Error opening CSV file for writing!\n");
        return 1;
    }
    fprintf(csv_file, "threads_per_block,batch_size,throughput_gbps,pcap_loops,matches_per_loop,total_matches\n");

    printf("====================================================================================\n");
    printf("GPU TUNER WITH L4 PAYLOAD DECAPSULATION (%s)\n", rules_path);
    printf("====================================================================================\n");

    // Load and build Aho-Corasick automaton
    AC_Automata *m = ac_create();
    load_patterns(m, rules_path);
    ac_finalize(m);

    char errbuf[PCAP_ERRBUF_SIZE];
    pcap_t *pcap = pcap_open_offline(pcap_path, errbuf);
    if (!pcap) {
        fprintf(stderr, "Error opening PCAP: %s\n", errbuf);
        fclose(csv_file);
        return 1;
    }

    struct pcap_pkthdr header;
    const u_char *packet;
    uint32_t valid_packet_count = 0;
    size_t total_payload_bytes = 0;

    // PASS 1: Count TCP/UDP packets with payload > 0
    while ((packet = pcap_next(pcap, &header)) != NULL) {
        uint32_t len = header.caplen;
        uint32_t hdr_offset = sizeof(struct ether_header);

        if (len <= hdr_offset) continue;

        struct ip *ip_hdr = (struct ip *)(packet + hdr_offset);
        hdr_offset += ip_hdr->ip_hl * 4;

        if (ip_hdr->ip_p == IPPROTO_TCP) {
            struct tcphdr *tcp_hdr = (struct tcphdr *)(packet + hdr_offset);
            hdr_offset += tcp_hdr->th_off * 4;
        } else if (ip_hdr->ip_p == IPPROTO_UDP) {
            hdr_offset += sizeof(struct udphdr);
        } else {
            continue;
        }

        uint32_t payload_len = (len > hdr_offset) ? len - hdr_offset : 0;
        if (payload_len > MAX_PAYLOAD_SIZE) payload_len = MAX_PAYLOAD_SIZE;

        if (payload_len > 0) {
            valid_packet_count++;
            total_payload_bytes += payload_len;
        }
    }
    pcap_close(pcap);

    printf("Filtered %u L4 payloads (%.2f GB) from PCAP.\n", valid_packet_count, (double)total_payload_bytes / (1024*1024*1024));

    // Allocate host memory for payloads and metadata
    char *h_flat_payloads = (char*)malloc(total_payload_bytes);
    size_t *h_offsets = (size_t*)malloc(valid_packet_count * sizeof(size_t));
    uint32_t *h_lens = (uint32_t*)malloc(valid_packet_count * sizeof(uint32_t));

    // PASS 2: Extract payloads and copy them into host memory
    pcap = pcap_open_offline(pcap_path, errbuf);
    uint32_t idx = 0;
    size_t current_offset = 0;

    while ((packet = pcap_next(pcap, &header)) != NULL && idx < valid_packet_count) {
        uint32_t len = header.caplen;
        uint32_t hdr_offset = sizeof(struct ether_header);

        if (len <= hdr_offset) continue;

        struct ip *ip_hdr = (struct ip *)(packet + hdr_offset);
        hdr_offset += ip_hdr->ip_hl * 4;

        if (ip_hdr->ip_p == IPPROTO_TCP) {
            struct tcphdr *tcp_hdr = (struct tcphdr *)(packet + hdr_offset);
            hdr_offset += tcp_hdr->th_off * 4;
        } else if (ip_hdr->ip_p == IPPROTO_UDP) {
            hdr_offset += sizeof(struct udphdr);
        } else {
            continue;
        }

        uint32_t payload_len = (len > hdr_offset) ? len - hdr_offset : 0;
        if (payload_len > MAX_PAYLOAD_SIZE) payload_len = MAX_PAYLOAD_SIZE;

        if (payload_len > 0) {
            h_lens[idx] = payload_len;
            h_offsets[idx] = current_offset;
            memcpy(h_flat_payloads + current_offset, packet + hdr_offset, payload_len);
            current_offset += payload_len;
            idx++;
        }
    }
    pcap_close(pcap);

    int *d_trans = NULL, *d_out = NULL;
    char *d_flat_payloads = NULL;
    size_t *d_offsets = NULL;
    uint32_t *d_lens = NULL;
    unsigned long long *d_matches = NULL;

    size_t trans_size = (size_t)m->capacity * ALPHABET_SIZE * sizeof(int);
    size_t out_size = (size_t)m->capacity * sizeof(int);

    // Allocate GPU device memory
    CUDA_CHECK(cudaMalloc((void**)&d_trans, trans_size));
    CUDA_CHECK(cudaMalloc((void**)&d_out, out_size));
    CUDA_CHECK(cudaMalloc((void**)&d_flat_payloads, total_payload_bytes));
    CUDA_CHECK(cudaMalloc((void**)&d_offsets, valid_packet_count * sizeof(size_t)));
    CUDA_CHECK(cudaMalloc((void**)&d_lens, valid_packet_count * sizeof(uint32_t)));
    CUDA_CHECK(cudaMalloc((void**)&d_matches, sizeof(unsigned long long)));

    // Copy data from host to device
    CUDA_CHECK(cudaMemcpy(d_trans, m->transition_table, trans_size, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_out, m->output_counts, out_size, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_flat_payloads, h_flat_payloads, total_payload_bytes, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_offsets, h_offsets, valid_packet_count * sizeof(size_t), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_lens, h_lens, valid_packet_count * sizeof(uint32_t), cudaMemcpyHostToDevice));

    // Define grid search options for threads per block and batch size
    int threads_options[] = {32, 64, 128, 256, 512, 1024};
    uint32_t batch_options[] = {256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131073};

    int num_threads_opt = sizeof(threads_options) / sizeof(threads_options[0]);
    int num_batch_opt = sizeof(batch_options) / sizeof(batch_options[0]);

    double best_throughput = 0.0;
    int best_threads = 0;
    uint32_t best_batch = 0;

    printf("\n%-12s | %-10s | %-15s | %-8s | %-16s | %-16s\n", 
           "Th/Block", "Batch Size", "Throughput", "Loops", "Matches/Loop", "Total Matches");
    printf("-----------------------------------------------------------------------------------------------\n");

    // Grid search loop over all configurations
    for (int t = 0; t < num_threads_opt; t++) {
        for (int b = 0; b < num_batch_opt; b++) {
            int th = threads_options[t];
            uint32_t bt = batch_options[b];

            TestResult res = test_configuration(
                th, bt, d_flat_payloads, d_offsets, d_lens, 
                valid_packet_count, total_payload_bytes, d_trans, d_out, d_matches
            );

            printf("%-12d | %-10u | %-12.2f Gbps   | %-8llu | %-16llu | %-16llu\n", 
                   th, bt, res.throughput_gbps, res.pcap_loops, res.matches_per_loop, res.total_matches);

            fprintf(csv_file, "%d,%u,%.2f,%llu,%llu,%llu\n", 
                    th, bt, res.throughput_gbps, res.pcap_loops, res.matches_per_loop, res.total_matches);
            fflush(csv_file);

            if (res.throughput_gbps > best_throughput) {
                best_throughput = res.throughput_gbps;
                best_threads = th;
                best_batch = bt;
            }
        }
    }

    fclose(csv_file);

    printf("-----------------------------------------------------------------------------------------------\n");
    printf("\nWINNING CONFIGURATION FOR STRICT PAYLOADS:\n");
    printf("   -> Threads per Block : %d\n", best_threads);
    printf("   -> Batch Size        : %u packets\n", best_batch);
    printf("   -> Peak Throughput   : %.2f Gbps\n\n", best_throughput);

    // Free device and host memory
    cudaFree(d_trans); cudaFree(d_out); cudaFree(d_flat_payloads);
    cudaFree(d_offsets); cudaFree(d_lens); cudaFree(d_matches);
    free(h_flat_payloads); free(h_offsets); free(h_lens);
    ac_free(m);

    return 0;
}