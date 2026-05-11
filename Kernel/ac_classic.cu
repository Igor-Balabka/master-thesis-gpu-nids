#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "../ac.h"
#include "ac_classic.h"
#include "cuda_utils.h"
#include "payload.h"

// GPU Kernel: Classic version where each thread scans one packet
__global__ void ac_classic_kernel(
    const int *__restrict__ d_table,
    const int *__restrict__ d_output_counts,
    const char *__restrict__ d_payload,
    const unsigned long *__restrict__ d_packet_start,
    const int *__restrict__ d_packet_lengths,
    int num_packets,
    long *d_results)
{
    long tid = (long)blockIdx.x * blockDim.x + threadIdx.x;
    if (tid >= num_packets)
        return;

    // Get the start position and size of the packet
    unsigned long start = d_packet_start[tid];
    int len = d_packet_lengths[tid];

    int state = 0;
    long matches = 0;

    // Process every byte of the packet
    for (int i = 0; i < len; i++)
    {
        unsigned char c = (unsigned char)d_payload[start + i];
        state = __ldg(&d_table[state * 256 + c]);
        matches += __ldg(&d_output_counts[state]);
    }

    // Write result for this packet
    d_results[tid] = matches;
}

void prepare_classic_metadata(MbufPool *pool, unsigned long *h_packet_start, int *h_packet_lengths)
{
    for (int i = 0; i < pool->packet_count; i++)
    {
        h_packet_start[i] = (unsigned long)((char *)pool->mbuf_array[i].buf_addr - (char *)pool->mempool_data);
        h_packet_lengths[i] = pool->mbuf_array[i].data_len;
    }
}

void cleanup_classic_gpu(int *d_table, int *d_output_counts, char *d_payload,
                         unsigned long *d_packet_start, int *d_packet_lengths, long *d_results)
{
    if (d_table)
        CUDA_CHECK(cudaFree(d_table));
    if (d_output_counts)
        CUDA_CHECK(cudaFree(d_output_counts));
    if (d_payload)
        CUDA_CHECK(cudaFree(d_payload));
    if (d_packet_start)
        CUDA_CHECK(cudaFree(d_packet_start));
    if (d_packet_lengths)
        CUDA_CHECK(cudaFree(d_packet_lengths));
    if (d_results)
        CUDA_CHECK(cudaFree(d_results));
}

extern "C"
{

    /**
     * Run the classic benchmark (Simple copy then compute)
     * This function copies EVERYTHING to the GPU at once before starting the kernel. --> Synchronously
     */
    double run_classic_packet_benchmark(const AC_Automata *m, MbufPool *pool, int loops, long *out_matches)
    {
        int num_packets = pool->packet_count;
        if (num_packets <= 0)
            return 0.0;

        size_t total_data_size = pool->total_bytes;

        // 1. Prepare packet info (offsets and lengths)
        unsigned long *h_packet_start = (unsigned long *)malloc(num_packets * sizeof(unsigned long));
        int *h_packet_lengths = (int *)malloc(num_packets * sizeof(int));

        prepare_classic_metadata(pool, h_packet_start, h_packet_lengths);

        // Access the pinned memory pool
        char *pinned_payload = (char *)pool->mempool_data;

        int *d_table, *d_output_counts, *d_packet_lengths;
        char *d_payload;
        unsigned long *d_packet_start;
        long *d_results;

        // Kernel configuration
        int num_threads = 256;
        int num_blocks = (num_packets + num_threads - 1) / num_threads;

        // 2. GPU Allocation
        CUDA_CHECK(cudaMalloc(&d_table, m->capacity * 256 * sizeof(int)));
        CUDA_CHECK(cudaMalloc(&d_output_counts, m->capacity * sizeof(int)));
        CUDA_CHECK(cudaMalloc(&d_payload, total_data_size));
        CUDA_CHECK(cudaMalloc(&d_packet_start, num_packets * sizeof(unsigned long)));
        CUDA_CHECK(cudaMalloc(&d_packet_lengths, num_packets * sizeof(int)));
        CUDA_CHECK(cudaMalloc(&d_results, num_packets * sizeof(long)));
        CUDA_CHECK(cudaMemcpy(d_table, m->transition_table, m->capacity * 256 * sizeof(int), cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_output_counts, m->output_counts, m->capacity * sizeof(int), cudaMemcpyHostToDevice));

        // 3. Data Transfer (Synchronous)
        // In this mode, we copy all data before starting the timer to measure raw kernel performance
        CUDA_CHECK(cudaMemcpy(d_payload, pinned_payload, total_data_size, cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_packet_start, h_packet_start, num_packets * sizeof(unsigned long), cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_packet_lengths, h_packet_lengths, num_packets * sizeof(int), cudaMemcpyHostToDevice));

        // Time measurement
        cudaEvent_t start_ev, stop_ev;
        cudaEventCreate(&start_ev);
        cudaEventCreate(&stop_ev);
        cudaEventRecord(start_ev);

        // 4. Kernel Execution Loop
        for (int i = 0; i < loops; i++)
        {
            ac_classic_kernel<<<num_blocks, num_threads>>>(d_table, d_output_counts, d_payload,
                                                           d_packet_start, d_packet_lengths,
                                                           num_packets, d_results);
        }

        cudaEventRecord(stop_ev);
        cudaEventSynchronize(stop_ev);

        float ms = 0;
        cudaEventElapsedTime(&ms, start_ev, stop_ev);

        // 5. Results collection
        long *h_results = (long *)malloc(num_packets * sizeof(long));
        CUDA_CHECK(cudaMemcpy(h_results, d_results, num_packets * sizeof(long), cudaMemcpyDeviceToHost));

        long total = 0;
        for (int i = 0; i < num_packets; i++)
            total += h_results[i];
        *out_matches = total;

        // Cleanup
        free(h_results);
        free(h_packet_start);
        free(h_packet_lengths);

        cleanup_classic_gpu(d_table, d_output_counts, d_payload, d_packet_start, d_packet_lengths, d_results);

        cudaEventDestroy(start_ev);
        cudaEventDestroy(stop_ev);

        // Return average time in seconds
        return ((double)ms / 1000.0) / loops;
    }
}