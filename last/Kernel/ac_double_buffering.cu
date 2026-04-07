#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "../ac.h"
#include "ac_double_buffering.h"
#include "cuda_utils.h"

__global__ void ac_buffering_kernel(
    const int * __restrict__ d_table, 
    const int * __restrict__ d_output_counts, 
    const char * __restrict__ d_payload, 
    const unsigned long * __restrict__ d_packet_start, 
    const int * __restrict__ d_packet_lengths, 
    int n_pkts_in_batch, 
    long * d_results_at_offset) 
{
    long tid = (long)blockIdx.x * blockDim.x + threadIdx.x;
    if (tid >= n_pkts_in_batch) return;

    unsigned long start = d_packet_start[tid];
    int len = d_packet_lengths[tid];
    
    int state = 0; 
    long matches = 0;

    for (int j = 0; j < len; j++) {
        unsigned char c = (unsigned char)d_payload[start + j];
        state = __ldg(&d_table[state * 256 + c]);
        matches += __ldg(&d_output_counts[state]);
    }

    d_results_at_offset[tid] = matches;
}

extern "C" {
double run_buffering_packet_benchmark(
    const AC_Machine *m, const char *payload, unsigned long *packet_start, 
    int *packet_lengths, int num_packets, int loops, long *out_matches, 
    int threads_per_block, int batch_size) 
{
    if (num_packets <= 0) return 0.0;

    int *d_table, *d_output_counts, *d_packet_lengths;
    char *d_payload;
    unsigned long *d_packet_start;
    long *d_results;

    // --- SÉCURITÉ 64-BIT ---
    size_t last_pkt_idx = (size_t)num_packets - 1;
    size_t total_data_size = (size_t)packet_start[last_pkt_idx] + (size_t)packet_lengths[last_pkt_idx];

    CUDA_CHECK(cudaMalloc(&d_table, (size_t)m->capacity * 256 * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_output_counts, (size_t)m->capacity * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_payload, total_data_size));
    CUDA_CHECK(cudaMalloc(&d_packet_start, (size_t)num_packets * sizeof(unsigned long)));
    CUDA_CHECK(cudaMalloc(&d_packet_lengths, (size_t)num_packets * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_results, (size_t)num_packets * sizeof(long)));


    CUDA_CHECK(cudaMemcpy(d_table, m->transition_table, (size_t)m->capacity * 256 * sizeof(int), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_output_counts, m->output_counts, (size_t)m->capacity * sizeof(int), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_packet_start, packet_start, (size_t)num_packets * sizeof(unsigned long), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_packet_lengths, packet_lengths, (size_t)num_packets * sizeof(int), cudaMemcpyHostToDevice));



    

    cudaStream_t streams[2];
    cudaStreamCreate(&streams[0]);
    cudaStreamCreate(&streams[1]);

    cudaEvent_t start_ev, stop_ev;
    cudaEventCreate(&start_ev); cudaEventCreate(&stop_ev);
    cudaDeviceSynchronize();
    

    cudaDeviceSynchronize();
    cudaEventRecord(start_ev);

    CUDA_CHECK(cudaMemcpy(d_payload, payload, total_data_size, cudaMemcpyHostToDevice));

    for (int l = 0; l < loops; l++) {
        // Remise à zéro propre des résultats
        cudaMemsetAsync(d_results, 0, (size_t)num_packets * sizeof(long), streams[0]);
        cudaStreamSynchronize(streams[0]);

        for (int i = 0; i < num_packets; i += batch_size) { 
            int s = (i / batch_size) % 2; 
            int n_pkts = (i + batch_size > num_packets) ? (num_packets - i) : batch_size;

            int blocks = (n_pkts + threads_per_block - 1) / threads_per_block;
        ac_buffering_kernel<<<blocks, threads_per_block, 0, streams[s]>>>(
            d_table, d_output_counts, d_payload,
            d_packet_start + i,
            d_packet_lengths + i,
            n_pkts,
            d_results + i
        );
        }
        cudaStreamSynchronize(streams[0]);
        cudaStreamSynchronize(streams[1]);
    }

    cudaEventRecord(stop_ev);
cudaEventSynchronize(stop_ev);

    float ms = 0;
    cudaEventElapsedTime(&ms, start_ev, stop_ev);

    // Récupération finale
    long *h_results = (long*)malloc((size_t)num_packets * sizeof(long));
    CUDA_CHECK(cudaMemcpy(h_results, d_results, (size_t)num_packets * sizeof(long), cudaMemcpyDeviceToHost));
    
    long total = 0;
    for(int i = 0; i < num_packets; i++) {
        total += h_results[i];
    }
    *out_matches = total;

    free(h_results);
    cudaFree(d_table); cudaFree(d_output_counts);
    cudaFree(d_payload); cudaFree(d_packet_start);
    cudaFree(d_packet_lengths); cudaFree(d_results);
    cudaStreamDestroy(streams[0]); cudaStreamDestroy(streams[1]);
    cudaEventDestroy(start_ev); cudaEventDestroy(stop_ev);

    return (double)ms / 1000.0 / loops;
}
}