#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "../ac.h"
#include "ac_double_buffering.h"
#include "cuda_utils.h"
#include "payload.h" 

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

    const unsigned char* payload_ptr = (const unsigned char*)d_payload;
    for (int j = 0; j < len; j++) {
        unsigned char c = payload_ptr[start + j];
        state = __ldg(&d_table[state * 256 + c]); 
        matches += __ldg(&d_output_counts[state]);
    }

    d_results_at_offset[tid] = matches;
}

extern "C" {
double run_mbuf_benchmark(
    const AC_Machine *m, MbufPool *pool, int loops, long *out_matches, 
    int threads_per_block, int batch_size, int n_slots) 
{
    int num_packets = pool->packet_count;
    if (num_packets <= 0) return 0.0;
    
    size_t total_data_size = pool->total_bytes;

    // 1. using arrays for the GPU (faster)
    unsigned long *h_packet_start = (unsigned long *)malloc(num_packets * sizeof(unsigned long));
    int *h_packet_lengths = (int *)malloc(num_packets * sizeof(int));
    
    for(int i = 0; i < num_packets; i++) {
        h_packet_start[i] = (unsigned long)((char*)pool->mbuf_array[i].buf_addr - (char*)pool->mempool_data);
        h_packet_lengths[i] = pool->mbuf_array[i].data_len;
    }

    char *pinned_payload = (char *)pool->mempool_data;

    int *d_table, *d_output_counts, *d_packet_lengths;
    char *d_payload;
    unsigned long *d_packet_start;
    long *d_results;

    // 2. GPU allocation
    CUDA_CHECK(cudaMalloc(&d_table, (size_t)m->capacity * 256 * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_output_counts, (size_t)m->capacity * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_payload, total_data_size));
    CUDA_CHECK(cudaMalloc(&d_packet_start, (size_t)num_packets * sizeof(unsigned long)));
    CUDA_CHECK(cudaMalloc(&d_packet_lengths, (size_t)num_packets * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_results, (size_t)num_packets * sizeof(long)));

    // 3. Copy to the GPU
    CUDA_CHECK(cudaMemcpy(d_table, m->transition_table, (size_t)m->capacity * 256 * sizeof(int), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_output_counts, m->output_counts, (size_t)m->capacity * sizeof(int), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_packet_start, h_packet_start, (size_t)num_packets * sizeof(unsigned long), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_packet_lengths, h_packet_lengths, (size_t)num_packets * sizeof(int), cudaMemcpyHostToDevice));    

    cudaStream_t *streams = (cudaStream_t*)malloc(n_slots * sizeof(cudaStream_t));
    for (int i = 0; i < n_slots; i++) {
        cudaStreamCreate(&streams[i]);
    }

    cudaEvent_t start_ev, stop_ev;
    cudaEventCreate(&start_ev); 
    cudaEventCreate(&stop_ev);
    
    cudaDeviceSynchronize();
    cudaEventRecord(start_ev,0);
    
    for (int l = 0; l < loops; l++) {
        for (int i = 0; i < num_packets; i += batch_size) { 
            int s = (i / batch_size) % n_slots; 
            int n_pkts = (i + batch_size > num_packets) ? (num_packets - i) : batch_size;

            unsigned long batch_offset = h_packet_start[i];
            size_t last_idx_in_batch = i + n_pkts - 1;
            size_t batch_end = (size_t)h_packet_start[last_idx_in_batch] + (size_t)h_packet_lengths[last_idx_in_batch];
            size_t batch_payload_size = batch_end - batch_offset;

            // sending to the GPU (async)
            cudaMemcpyAsync(d_payload + batch_offset, 
                        pinned_payload + batch_offset, 
                        batch_payload_size, 
                        cudaMemcpyHostToDevice, 
                        streams[s]);
                        
            int blocks = (n_pkts + threads_per_block - 1) / threads_per_block;            
            
            ac_buffering_kernel<<<blocks, threads_per_block, 0, streams[s]>>>(
                d_table, d_output_counts, d_payload,
                d_packet_start + i,
                d_packet_lengths + i,
                n_pkts,
                d_results + i
            );
        }
    }
    
    
    cudaEventRecord(stop_ev,0);
    cudaEventSynchronize(stop_ev);


    float ms = 0;
    cudaEventElapsedTime(&ms, start_ev, stop_ev);

    // Getting back the result
    long *h_results = (long*)malloc((size_t)num_packets * sizeof(long));
    CUDA_CHECK(cudaMemcpy(h_results, d_results, (size_t)num_packets * sizeof(long), cudaMemcpyDeviceToHost));
    
    long total = 0;
    for(int i = 0; i < num_packets; i++) {
        total += h_results[i];
    }
    *out_matches = total;

    // Libération
    free(h_packet_start); free(h_packet_lengths); free(h_results);
    cudaFree(d_table); cudaFree(d_output_counts);
    cudaFree(d_payload); cudaFree(d_packet_start);
    cudaFree(d_packet_lengths); cudaFree(d_results);
    
    for (int i = 0; i < n_slots; i++) {
        cudaStreamDestroy(streams[i]);
    }
    free(streams);
    cudaEventDestroy(start_ev); cudaEventDestroy(stop_ev);
    printf("\n[DEBUG GPU] ms raw: %f\n", ms);
    return (double)ms / 1000.0 / loops;
}
}