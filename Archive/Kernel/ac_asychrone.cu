#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "../ac.h"
#include "ac_asychrone.h"
#include "cuda_utils.h"
#include "payload.h"

// GPU Kernel: Each thread handles one packet
__global__ void ac_buffering_kernel(
    const int *__restrict__ d_table,
    const int *__restrict__ d_output_counts,
    const char *__restrict__ d_payload,
    const unsigned long *__restrict__ d_packet_start,
    const int *__restrict__ d_packet_lengths,
    int n_pkts_in_batch,
    long *d_results_at_offset)
{
    long tid = (long)blockIdx.x * blockDim.x + threadIdx.x;
    if (tid >= n_pkts_in_batch)
        return;

    // Find where my packet starts and its length
    unsigned long start = d_packet_start[tid];
    int len = d_packet_lengths[tid];

    int state = 0;
    long matches = 0;

    // Standard Aho-Corasick logic
    const unsigned char *payload_ptr = (const unsigned char *)d_payload;
    for (int j = 0; j < len; j++)
    {
        unsigned char c = payload_ptr[start + j];
        state = __ldg(&d_table[state * 256 + c]);
        matches += __ldg(&d_output_counts[state]);
    }

    // Save the number of matches for this specific packet
    d_results_at_offset[tid] = matches;
}

extern "C"
{
    double run_mbuf_benchmark(
        const AC_Automata *m, MbufPool *pool, int loops, long *out_matches,
        int block_size, int batch_size, int n_slots)
    {
        int num_packets = pool->packet_count;
        if (num_packets <= 0)
            return 0.0;

        size_t total_data_size = pool->total_bytes;

        // 1. Prepare packet info arrays on Host
        // We store where each packet starts relative to the beginning of the memory pool
        unsigned long *h_packet_start = (unsigned long *)malloc(num_packets * sizeof(unsigned long));
        int *h_packet_lengths = (int *)malloc(num_packets * sizeof(int));
        prepare_packet_metadata(pool, h_packet_start, h_packet_lengths);

        // Pointer to our Pinned Memory
        char *pinned_payload = (char *)pool->mempool_data;

        int *d_table, *d_output_counts, *d_packet_lengths;
        char *d_payload;
        unsigned long *d_packet_start;
        long *d_results;

        // 2. GPU Memory Allocation
        CUDA_CHECK(cudaMalloc(&d_table, (size_t)m->capacity * 256 * sizeof(int)));
        CUDA_CHECK(cudaMalloc(&d_output_counts, (size_t)m->capacity * sizeof(int)));
        CUDA_CHECK(cudaMalloc(&d_payload, total_data_size));
        CUDA_CHECK(cudaMalloc(&d_packet_start, (size_t)num_packets * sizeof(unsigned long)));
        CUDA_CHECK(cudaMalloc(&d_packet_lengths, (size_t)num_packets * sizeof(int)));
        CUDA_CHECK(cudaMalloc(&d_results, (size_t)num_packets * sizeof(long)));

        // 3. Transfers to the GPU
        CUDA_CHECK(cudaMemcpy(d_table, m->transition_table, (size_t)m->capacity * 256 * sizeof(int), cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_output_counts, m->output_counts, (size_t)m->capacity * sizeof(int), cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_packet_start, h_packet_start, (size_t)num_packets * sizeof(unsigned long), cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_packet_lengths, h_packet_lengths, (size_t)num_packets * sizeof(int), cudaMemcpyHostToDevice));

        // Create multiple streams for overlapping copies and Kernel execution
        cudaStream_t *streams = (cudaStream_t *)malloc(n_slots * sizeof(cudaStream_t));
        for (int i = 0; i < n_slots; i++)
        {
            cudaStreamCreate(&streams[i]);
        }

        // Events for precise time measurement
        cudaEvent_t start_ev, stop_ev;
        cudaEventCreate(&start_ev);
        cudaEventCreate(&stop_ev);

        cudaDeviceSynchronize();
        cudaEventRecord(start_ev, 0);

        // Main processing loop
        for (int l = 0; l < loops; l++)
        {
            for (int i = 0; i < num_packets; i += batch_size)
            {
                // Pick the correct stream slot
                int s = (i / batch_size) % n_slots;
                int n_pkts = (i + batch_size > num_packets) ? (num_packets - i) : batch_size;

                // Calculate the payload size for the current batch
                unsigned long batch_offset = h_packet_start[i];
                size_t last_idx_in_batch = i + n_pkts - 1;
                size_t batch_end = (size_t)h_packet_start[last_idx_in_batch] + (size_t)h_packet_lengths[last_idx_in_batch];
                size_t batch_payload_size = batch_end - batch_offset;

                // Copy batch payloads to GPU asynchronously
                cudaMemcpyAsync(d_payload + batch_offset,
                                pinned_payload + batch_offset,
                                batch_payload_size,
                                cudaMemcpyHostToDevice,
                                streams[s]);

                // Launching the kernel on the correct stream
                int blocks = (n_pkts + block_size - 1) / block_size;
                ac_buffering_kernel<<<blocks, block_size, 0, streams[s]>>>(
                    d_table, d_output_counts, d_payload,
                    d_packet_start + i,
                    d_packet_lengths + i,
                    n_pkts,
                    d_results + i);
            }
        }

        cudaEventRecord(stop_ev, 0);
        cudaEventSynchronize(stop_ev);

        float ms = 0;
        cudaEventElapsedTime(&ms, start_ev, stop_ev);

        // Get results back to Host to verify the total number of matches
        long *h_results = (long *)malloc((size_t)num_packets * sizeof(long));
        CUDA_CHECK(cudaMemcpy(h_results, d_results, (size_t)num_packets * sizeof(long), cudaMemcpyDeviceToHost));

        long total = 0;
        for (int i = 0; i < num_packets; i++)
        {
            total += h_results[i];
        }
        *out_matches = total;

        // Cleanup everything
        free(h_packet_start);
        free(h_packet_lengths);
        free(h_results);
        cleanup_gpu(d_table, d_output_counts, d_payload, d_packet_start, d_packet_lengths, d_results, streams, n_slots);
        cudaEventDestroy(start_ev);
        cudaEventDestroy(stop_ev);

        return (double)ms / 1000.0 / loops;
    }
}