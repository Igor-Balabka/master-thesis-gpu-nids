#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "../ac.h"
#include "ac_classic.h"
#include "cuda_utils.h"



__global__ void ac_classic_kernel(int *d_table, int *d_output_counts, char *d_payload, long *d_packet_start, int *d_packet_lengths, int num_packets, long *d_results) {
    long tid = (long)blockIdx.x * blockDim.x + threadIdx.x;
    if (tid >= num_packets) return;

    long start = d_packet_start[tid];
    int len = d_packet_lengths[tid];
    
    int state = 0; 
    long matches = 0;

    for (int i = 0; i < len; i++) {
        unsigned char c = (unsigned char)d_payload[start + i];

        // state = d_table[state * 256 + c];
        // if (d_output_counts[state] > 0) {
        //      matches += d_output_counts[state];
        //  }
         
        //Optimization : From 30 gbps to 64 gbps

        state = __ldg(&d_table[state * 256 + c]);
        matches += __ldg(&d_output_counts[state]);
    }

    d_results[tid] = matches;
}


extern "C" {
double run_classic_packet_benchmark(const AC_Machine *m, const char *payload, long *packet_start, int *packet_lengths, int num_packets, int loops, long *out_matches) {
    if (num_packets <= 0) return 0.0;

    int *d_table = NULL;
    int *d_output_counts = NULL;
    int *d_packet_lengths = NULL;
    char *d_payload = NULL;
    long *d_packet_start = NULL;
    long *d_results = NULL;

    int num_threads = 256;
    int num_blocks = (num_packets + num_threads - 1) / num_threads;

    size_t total_data_size = (size_t)packet_start[num_packets-1] + packet_lengths[num_packets-1];

    CUDA_CHECK(cudaMalloc(&d_table, m->capacity * 256 * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_output_counts, m->capacity * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_payload, total_data_size));
    CUDA_CHECK(cudaMalloc(&d_packet_start, num_packets * sizeof(long)));
    CUDA_CHECK(cudaMalloc(&d_packet_lengths, num_packets * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_results, num_packets * sizeof(long)));

    CUDA_CHECK(cudaMemcpy(d_table, m->transition_table, m->capacity * 256 * sizeof(int), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_output_counts, m->output_counts, m->capacity * sizeof(int), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_payload, payload, total_data_size, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_packet_start, packet_start, num_packets * sizeof(long), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_packet_lengths, packet_lengths, num_packets * sizeof(int), cudaMemcpyHostToDevice));

    cudaEvent_t start, stop;
    cudaEventCreate(&start); cudaEventCreate(&stop);
    cudaEventRecord(start);

    for (int i = 0; i < loops; i++) {
        ac_classic_kernel<<<num_blocks, num_threads>>>(d_table, d_output_counts, d_payload, 
                                                       d_packet_start, d_packet_lengths, 
                                                       num_packets, d_results);
    }

    cudaEventRecord(stop);
    cudaEventSynchronize(stop); 
    float ms = 0;
    cudaEventElapsedTime(&ms, start, stop);

    long *h_results = (long*)malloc(num_packets * sizeof(long));
    CUDA_CHECK(cudaMemcpy(h_results, d_results, num_packets * sizeof(long), cudaMemcpyDeviceToHost));
    
    long total = 0;
    for(int i = 0; i < num_packets; i++) {
        total += h_results[i];
    }
    *out_matches = total;

    free(h_results);
    CUDA_CHECK(cudaFree(d_table));
    CUDA_CHECK(cudaFree(d_output_counts));
    CUDA_CHECK(cudaFree(d_payload));
    CUDA_CHECK(cudaFree(d_packet_start));
    CUDA_CHECK(cudaFree(d_packet_lengths));
    CUDA_CHECK(cudaFree(d_results));
    cudaEventDestroy(start);
    cudaEventDestroy(stop);

    return (double)ms / 1000.0; 
}
}