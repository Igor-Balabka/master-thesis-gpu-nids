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
#include <unistd.h>

extern "C" {
    #include "../../ac.h" 
}

#define ALPHABET_SIZE 256
#define DURATION_SECONDS 120.0 // Test duration: 2 minutes (120s)
#define MAX_PAYLOAD_SIZE 1500

// Macro to check CUDA errors and exit if something fails
#define CUDA_CHECK(call) \
    do { \
        cudaError_t err = call; \
        if (err != cudaSuccess) { \
            fprintf(stderr, "CUDA Error at %s:%d - %s\n", __FILE__, __LINE__, cudaGetErrorString(err)); \
            exit(EXIT_FAILURE); \
        } \
    } while (0)

// CUDA kernel for pure VRAM Aho-Corasick pattern matching
__global__ void aho_corasick_vram_kernel(
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

    // Traverse the automaton for each byte of the payload
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

int main(int argc, char **argv) {
    const char *pcap_path = "/dev/shm/MixFile.pcap";
    const char *rules_path = "../../Rules/patterns.txt";

    if (argc > 1) pcap_path = argv[1];
    if (argc > 2) rules_path = argv[2];

    // Selected optimized configuration from grid search
    int threadsPerBlock = 32;   
    uint32_t batch_size = 32768; 

    // Create directories and check CSV file
    mkdir("csv_results", 0777);
    mkdir("csv_results/GPU_in_memory", 0777);

    const char *csv_path = "csv_results/GPU_in_memory/gpu_vram_results.csv";
    int file_exists = (access(csv_path, F_OK) == 0);

    FILE *csv_file = fopen(csv_path, "a"); // Append mode to accumulate runs
    if (!csv_file) {
        fprintf(stderr, "Error opening CSV file: %s\n", csv_path);
        return 1;
    }

    // Write CSV header if the file is new
    if (!file_exists) {
        fprintf(csv_file, "run_id,threads_per_block,batch_size,throughput_gbps,pcap_loops,matches_per_loop,total_matches,elapsed_seconds\n");
        fflush(csv_file);
    }

    printf("==================================================\n");
    printf("GPU PURE VRAM COMPUTE BENCHMARK (120 SECONDS)\n");
    printf("==================================================\n");
    printf("Target PCAP  : %s\n", pcap_path);
    printf("Target Rules : %s\n", rules_path);
    printf("Config       : %d threads/block, batch size = %u\n", threadsPerBlock, batch_size);
    printf("Output CSV   : %s\n", csv_path);

    // 1. Load Aho-Corasick rules automaton
    AC_Automata *m = ac_create();
    load_patterns(m, rules_path);
    ac_finalize(m);

    // 2. Filter L4 payloads from PCAP (TCP/UDP only)
    char errbuf[PCAP_ERRBUF_SIZE];
    pcap_t *pcap = pcap_open_offline(pcap_path, errbuf);
    if (!pcap) {
        fprintf(stderr, "Error opening PCAP file: %s\n", errbuf);
        fclose(csv_file);
        return 1;
    }

    struct pcap_pkthdr header;
    const u_char *packet;
    uint32_t valid_packet_count = 0;
    size_t total_payload_bytes = 0;

    // PASS 1: Count packets with valid payloads
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

    // Allocate host memory for flat payloads and metadata
    char *h_flat_payloads = (char*)malloc(total_payload_bytes);
    size_t *h_offsets = (size_t*)malloc(valid_packet_count * sizeof(size_t));
    uint32_t *h_lens = (uint32_t*)malloc(valid_packet_count * sizeof(uint32_t));

    // PASS 2: Copy payload data into host memory
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

    // Copy data from host to device VRAM
    CUDA_CHECK(cudaMemcpy(d_trans, m->transition_table, trans_size, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_out, m->output_counts, out_size, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_flat_payloads, h_flat_payloads, total_payload_bytes, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_offsets, h_offsets, valid_packet_count * sizeof(size_t), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_lens, h_lens, valid_packet_count * sizeof(uint32_t), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemset(d_matches, 0, sizeof(unsigned long long)));

    // Warmup kernel execution
    uint32_t warmup_pkts = (valid_packet_count > batch_size) ? batch_size : valid_packet_count;
    int warmup_blocks = (warmup_pkts + threadsPerBlock - 1) / threadsPerBlock;
    aho_corasick_vram_kernel<<<warmup_blocks, threadsPerBlock>>>(d_flat_payloads, d_offsets, d_lens, 0, warmup_pkts, d_trans, d_out, d_matches);
    CUDA_CHECK(cudaDeviceSynchronize());
    CUDA_CHECK(cudaMemset(d_matches, 0, sizeof(unsigned long long)));

    struct timespec t_start, t_now;
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    unsigned long long pcap_loops = 0;
    unsigned long long total_matches = 0;
    unsigned long long matches_first_loop = 0;
    double elapsed_seconds = 0.0;

    // Main benchmark loop running for 120 seconds
    while (1) {
        uint32_t processed_in_loop = 0;

        while (processed_in_loop < valid_packet_count) {
            uint32_t pkts_to_process = (valid_packet_count - processed_in_loop > batch_size) ? 
                                       batch_size : (valid_packet_count - processed_in_loop);

            int blocks = (pkts_to_process + threadsPerBlock - 1) / threadsPerBlock;

            aho_corasick_vram_kernel<<<blocks, threadsPerBlock>>>(
                d_flat_payloads, d_offsets, d_lens, processed_in_loop, pkts_to_process, d_trans, d_out, d_matches
            );

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
        elapsed_seconds = (t_now.tv_sec - t_start.tv_sec) + (t_now.tv_nsec - t_start.tv_nsec) / 1e9;

        if (elapsed_seconds >= DURATION_SECONDS) {
            break;
        }
    }

    size_t total_processed_bytes = pcap_loops * total_payload_bytes;
    double total_processed_bits = (double)total_processed_bytes * 8.0;
    double throughput_gbps = total_processed_bits / (elapsed_seconds * 1e9);

    static int run_id = 1;

    // Write results to CSV file
    fprintf(csv_file, "%d,%d,%u,%.2f,%llu,%llu,%llu,%.2f\n", 
            run_id++, threadsPerBlock, batch_size, throughput_gbps, pcap_loops, matches_first_loop, total_matches, elapsed_seconds);
    fflush(csv_file);
    fclose(csv_file);

    printf("\n==================================================\n");
    printf("FINAL RESULTS (PURE VRAM EXECUTION)\n");
    printf("==================================================\n");
    printf("Test Duration          : %.2f seconds\n", elapsed_seconds);
    printf("PCAP Loops Completed   : %llu loops\n", pcap_loops);
    printf("Matches / Loop         : %llu\n", matches_first_loop);
    printf("Total Matches Found    : %llu\n", total_matches);
    printf("--------------------------------------------------\n");
    printf("PURE GPU VRAM THROUGHPUT : %.2f Gbps\n", throughput_gbps);
    printf("Results appended to      : %s\n", csv_path);
    printf("==================================================\n\n");

    // Free GPU device memory and host buffers
    cudaFree(d_trans); cudaFree(d_out); cudaFree(d_flat_payloads);
    cudaFree(d_offsets); cudaFree(d_lens); cudaFree(d_matches);
    free(h_flat_payloads); free(h_offsets); free(h_lens);
    ac_free(m);

    return 0;
}