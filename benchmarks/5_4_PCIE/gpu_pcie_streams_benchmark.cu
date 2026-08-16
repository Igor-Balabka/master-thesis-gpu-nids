#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <pcap.h>
#include <cuda_runtime.h>
#include <sys/stat.h>
#include <emmintrin.h>

#include <netinet/ether.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>

#include "../../config.h"

#define TEST_DURATION 20.0  // 20 seconds per test configuration
#define MAX_PAYLOAD_SIZE 1500

// Macro to check CUDA errors and exit on failure
#define CUDA_CHECK(call) \
    do { \
        cudaError_t err = call; \
        if (err != cudaSuccess) { \
            fprintf(stderr, "CUDA Error at %s:%d - %s\n", __FILE__, __LINE__, cudaGetErrorString(err)); \
            exit(EXIT_FAILURE); \
        } \
    } while (0)

// Function to benchmark pipeline throughput comparing pageable and pinned memory across streams
double run_pipeline_benchmark(
    int num_streams,
    bool use_pinned,
    uint32_t batch_size,
    char *h_flat_payloads,
    size_t *h_offsets,
    uint32_t *h_lens,
    uint32_t total_packets,
    size_t total_payload_bytes)
{
    // Allocate streams, events, and host/device buffers for each stream
    cudaStream_t *streams = (cudaStream_t*)malloc(num_streams * sizeof(cudaStream_t));
    cudaEvent_t *events = (cudaEvent_t*)malloc(num_streams * sizeof(cudaEvent_t));
    
    char **d_payloads = (char**)malloc(num_streams * sizeof(char*));
    uint32_t **d_lens = (uint32_t**)malloc(num_streams * sizeof(uint32_t*));
    
    char **h_data_buffers = (char**)malloc(num_streams * sizeof(char*));
    uint32_t **h_lens_buffers = (uint32_t**)malloc(num_streams * sizeof(uint32_t*));

    size_t batch_bytes = (size_t)batch_size * MAX_PAYLOAD_SIZE;
    size_t len_bytes = batch_size * sizeof(uint32_t);

    for (int i = 0; i < num_streams; i++) {
        CUDA_CHECK(cudaStreamCreateWithFlags(&streams[i], cudaStreamNonBlocking));
        CUDA_CHECK(cudaEventCreateWithFlags(&events[i], cudaEventDisableTiming));

        CUDA_CHECK(cudaMalloc((void**)&d_payloads[i], batch_bytes));
        CUDA_CHECK(cudaMalloc((void**)&d_lens[i], len_bytes));

        // Use pinned host memory or regular pageable memory based on the flag
        if (use_pinned) {
            CUDA_CHECK(cudaHostAlloc((void**)&h_data_buffers[i], batch_bytes, cudaHostAllocDefault));
            CUDA_CHECK(cudaHostAlloc((void**)&h_lens_buffers[i], len_bytes, cudaHostAllocDefault));
        } else {
            h_data_buffers[i] = (char*)malloc(batch_bytes);
            h_lens_buffers[i] = (uint32_t*)malloc(len_bytes);
        }
    }

    struct timespec t_start, t_now;
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    unsigned long long pcap_loops = 0;
    double elapsed = 0.0;

    // Main test loop running until the configured duration expires
    while (elapsed < TEST_DURATION) {
        uint32_t processed = 0;
        int stream_idx = 0;

        while (processed < total_packets) {
            uint32_t current_batch = (total_packets - processed > batch_size) ? batch_size : (total_packets - processed);

            for (uint32_t i = 0; i < current_batch; i++) {
                uint32_t idx = processed + i;
                h_lens_buffers[stream_idx][i] = h_lens[idx];
                memcpy(h_data_buffers[stream_idx] + (i * MAX_PAYLOAD_SIZE), h_flat_payloads + h_offsets[idx], h_lens[idx]);
            }

            // Wait until the current stream event is ready
            while (cudaEventQuery(events[stream_idx]) != cudaSuccess) {
                _mm_pause();
            }

            cudaStream_t stream = streams[stream_idx];
            size_t cur_batch_bytes = current_batch * MAX_PAYLOAD_SIZE;
            size_t cur_len_bytes = current_batch * sizeof(uint32_t);

            // Asynchronous Host-to-Device transfer (H2D)
            CUDA_CHECK(cudaMemcpyAsync(d_payloads[stream_idx], h_data_buffers[stream_idx], cur_batch_bytes, cudaMemcpyHostToDevice, stream));
            CUDA_CHECK(cudaMemcpyAsync(d_lens[stream_idx], h_lens_buffers[stream_idx], cur_len_bytes, cudaMemcpyHostToDevice, stream));

            // Asynchronous Device-to-Host transfer (D2H) to test bidirectional bandwidth
            CUDA_CHECK(cudaMemcpyAsync(h_data_buffers[stream_idx], d_payloads[stream_idx], cur_batch_bytes, cudaMemcpyDeviceToHost, stream));

            CUDA_CHECK(cudaEventRecord(events[stream_idx], stream));

            processed += current_batch;
            stream_idx = (stream_idx + 1) % num_streams;
        }

        CUDA_CHECK(cudaDeviceSynchronize());
        pcap_loops++;

        clock_gettime(CLOCK_MONOTONIC, &t_now);
        elapsed = (t_now.tv_sec - t_start.tv_sec) + (t_now.tv_nsec - t_start.tv_nsec) / 1e9;
    }

    // Calculate bidirectional throughput in Gbps (H2D + D2H)
    double total_bytes = (double)pcap_loops * total_payload_bytes * 2.0;
    double throughput_gbps = (total_bytes * 8.0) / (elapsed * 1e9);

    // Free all allocated memory and CUDA streams/events
    for (int i = 0; i < num_streams; i++) {
        cudaFree(d_payloads[i]);
        cudaFree(d_lens[i]);
        if (use_pinned) {
            cudaFreeHost(h_data_buffers[i]);
            cudaFreeHost(h_lens_buffers[i]);
        } else {
            free(h_data_buffers[i]);
            free(h_lens_buffers[i]);
        }
        cudaEventDestroy(events[i]);
        cudaStreamDestroy(streams[i]);
    }
    free(streams); free(events); free(d_payloads); free(d_lens); free(h_data_buffers); free(h_lens_buffers);

    return throughput_gbps;
}

int main(int argc, char **argv) {
    const char *pcap_path = "/dev/shm/MixFile.pcap";
    if (argc > 1) pcap_path = argv[1];

    char errbuf[PCAP_ERRBUF_SIZE];
    pcap_t *pcap = pcap_open_offline(pcap_path, errbuf);
    if (!pcap) return 1;
    
    struct pcap_pkthdr header;
    const u_char *packet;
    uint32_t valid_packet_count = 0;
    size_t total_payload_bytes = 0;

    // Pass 1: Count packets with valid L4 payloads
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
        } else continue;
        uint32_t payload_len = (len > hdr_offset) ? len - hdr_offset : 0;
        if (payload_len > MAX_PAYLOAD_SIZE) payload_len = MAX_PAYLOAD_SIZE;
        if (payload_len > 0) {
            valid_packet_count++;
            total_payload_bytes += payload_len;
        }
    }
    pcap_close(pcap);

    // Allocate host buffers for flat payloads, offsets, and lengths
    char *h_flat_payloads = (char*)malloc(total_payload_bytes);
    size_t *h_offsets = (size_t*)malloc(valid_packet_count * sizeof(size_t));
    uint32_t *h_lens = (uint32_t*)malloc(valid_packet_count * sizeof(uint32_t));

    // Pass 2: Extract payloads and copy them to host memory
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
        } else continue;
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

    uint32_t test_batch_size = 32768;
    int stream_counts[] = {1, 2, 4, 8, 16};
    int num_options = sizeof(stream_counts) / sizeof(stream_counts[0]);

    // Clean CSV format output for Bash script parsing
    for (int i = 0; i < num_options; i++) {
        int n_streams = stream_counts[i];
        double bw_pageable = run_pipeline_benchmark(n_streams, false, test_batch_size, h_flat_payloads, h_offsets, h_lens, valid_packet_count, total_payload_bytes);
        double bw_pinned = run_pipeline_benchmark(n_streams, true, test_batch_size, h_flat_payloads, h_offsets, h_lens, valid_packet_count, total_payload_bytes);
        
        printf("RESULT:%d,%.2f,%.2f\n", n_streams, bw_pageable, bw_pinned);
    }

    free(h_flat_payloads); free(h_offsets); free(h_lens);
    return 0;
}