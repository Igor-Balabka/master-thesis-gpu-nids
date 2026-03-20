#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "ac.h"
#include "ac_double_buffering.h"
#include "cuda_utils.h"

#define BATCH_SIZE 1024


__global__ void ac_buffering_kernel(int *d_table, int *d_output_counts, char *d_payload, long *d_packet_start, int *d_packet_lengths, int num_packets, long *d_results) {
    long tid = (long)blockIdx.x * blockDim.x + threadIdx.x;
    if (tid >= num_packets) return;

    long start = d_packet_start[tid];
    int len = d_packet_lengths[tid];
    
    int state = 0; 
    long matches = 0;

    for (int i = 0; i < len; i++) {
        unsigned char c = (unsigned char)d_payload[start + i];

        // if (d_output_counts[state] > 0) {
        //     matches += d_output_counts[state];
        // }
    
        //Optimization : From 38 gbps to 64 gbps
        state = __ldg(&d_table[state * 256 + c]);
        matches += __ldg(&d_output_counts[state]);
    }

    d_results[tid] = matches;
}



double run_buffering_packet_benchmark(const AC_Machine *m, const char *payload, long *packet_start, int *packet_lengths, int num_packets, int loops, long *out_matches, int threads_per_block) {
    if (num_packets <= 0) return 0.0;

    int *d_table, *d_output_counts, *d_packet_lengths;
    char *d_payload;
    long *d_packet_start, *d_results;

    size_t total_data_size = (size_t)packet_start[num_packets-1] + packet_lengths[num_packets-1];

    CUDA_CHECK(cudaMalloc(&d_table, m->capacity * 256 * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_output_counts, m->capacity * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_payload, total_data_size));
    CUDA_CHECK(cudaMalloc(&d_packet_start, num_packets * sizeof(long)));
    CUDA_CHECK(cudaMalloc(&d_packet_lengths, num_packets * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_results, num_packets * sizeof(long)));

    CUDA_CHECK(cudaMemcpy(d_table, m->transition_table, m->capacity * 256 * sizeof(int), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_output_counts, m->output_counts, m->capacity * sizeof(int), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_packet_start, packet_start, num_packets * sizeof(long), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_packet_lengths, packet_lengths, num_packets * sizeof(int), cudaMemcpyHostToDevice));

    cudaStream_t streams[2];
    cudaStreamCreate(&streams[0]);
    cudaStreamCreate(&streams[1]);

    cudaEvent_t start_ev, stop_ev;
    cudaEventCreate(&start_ev); cudaEventCreate(&stop_ev);
    cudaEventRecord(start_ev);


    int current_batch = 0;
    for (int l = 0; l < loops; l++) {
        for (int i = 0; i < num_packets; i += BATCH_SIZE) {
            if (current_batch == 1) {
                current_batch = 0;
            } else {
                current_batch = 1;
            }
            int n_pkts = (i + BATCH_SIZE > num_packets) ? (num_packets - i) : BATCH_SIZE;

            long offset_in_payload = packet_start[i];
            size_t batch_bytes = (i + n_pkts < num_packets) ? 
                                 (packet_start[i + n_pkts] - packet_start[i]) : 
                                 (total_data_size - packet_start[i]);

            cudaMemcpyAsync(d_payload + offset_in_payload, payload + offset_in_payload, 
                            batch_bytes, cudaMemcpyHostToDevice, streams[current_batch]);

            int blocks = (n_pkts + threads_per_block - 1) / threads_per_block;
            ac_buffering_kernel<<<blocks, threads_per_block, 0, streams[current_batch]>>>(
                d_table, d_output_counts, d_payload, 
                d_packet_start + i, d_packet_lengths + i, 
                n_pkts, d_results + i
            );
        }
    }

    cudaDeviceSynchronize(); 
    cudaEventRecord(stop_ev);
    cudaEventSynchronize(stop_ev);

    float ms = 0;
    cudaEventElapsedTime(&ms, start_ev, stop_ev);

    long *h_results = (long*)malloc(num_packets * sizeof(long));
    CUDA_CHECK(cudaMemcpy(h_results, d_results, num_packets * sizeof(long), cudaMemcpyDeviceToHost));
    long total = 0;
    for(int i = 0; i < num_packets; i++) total += h_results[i];
    *out_matches = total;

    free(h_results);
    CUDA_CHECK(cudaFree(d_table)); CUDA_CHECK(cudaFree(d_output_counts));
    CUDA_CHECK(cudaFree(d_payload)); CUDA_CHECK(cudaFree(d_packet_start));
    CUDA_CHECK(cudaFree(d_packet_lengths)); CUDA_CHECK(cudaFree(d_results));
    cudaStreamDestroy(streams[0]); cudaStreamDestroy(streams[1]);
    cudaEventDestroy(start_ev); cudaEventDestroy(stop_ev);

    return (double)ms / 1000.0;
}