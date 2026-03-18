#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "ac.h"
#include "gpu_ac.h"

/**
 * Helper macro for CUDA error checking.
 * In a high-performance NIDS, catching asynchronous errors is vital 
 * to avoid silent failures during packet processing.
 */
#define CUDA_CHECK(call) \
    do { \
        cudaError_t err = call; \
        if (err != cudaSuccess) { \
            fprintf(stderr, "CUDA Error: %s at line %d\n", cudaGetErrorString(err), __LINE__); \
            exit(EXIT_FAILURE); \
        } \
    } while(0)

// --- CUDA KERNELS ---

/**
 * print_gpu_specs: 
 * Queries the CUDA device properties to display hardware limits.
 * Essential for justifying the 'num_threads' (block size) choice in the thesis.
 */
extern "C" void print_gpu_specs() {
    int deviceId;
    cudaGetDevice(&deviceId);
    cudaDeviceProp props;
    cudaGetDeviceProperties(&props, deviceId);

    printf("\n--- GPU Hardware Specifications ---\n");
    printf("Device Name         : %s\n", props.name);
    printf("Global Memory       : %.2f GB\n", (float)props.totalGlobalMem / (1024 * 1024 * 1024));
    printf("Multiprocessors (SM): %d\n", props.multiProcessorCount);
    printf("Warp Size           : %d\n", props.warpSize);
    printf("Max Threads/Block   : %d\n", props.maxThreadsPerBlock);
    printf("Max Threads/SM      : %d\n", props.maxThreadsPerMultiProcessor);
    printf("Total CUDA Cores    : %d \n", props.multiProcessorCount * 128); 
    printf("-----------------------------------\n");
}


/**
 * ac_kernel_packets: Main Parallel Search Engine
 * Logic: One CUDA Thread per Network Packet.
 * * This approach ensures 100% detection accuracy by avoiding the "split-pattern" 
 * problem found in raw byte-stream chunking.
 */
__global__ void ac_kernel_packets(int *d_table, 
                                  int *d_output_counts, 
                                  char *d_payload, 
                                  long *d_packet_offsets, 
                                  int *d_packet_lengths,  
                                  int num_packets, 
                                  long *d_results) 
{
    // Map global thread ID to packet index
    long tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid >= num_packets) return;

    // Get the specific packet boundaries for this thread
    long start = d_packet_offsets[tid];
    int len = d_packet_lengths[tid];
    
    int state = 0; 
    long matches = 0;

    // Process each byte of the assigned packet
    for (int i = 0; i < len; i++) {
        unsigned char c = (unsigned char)d_payload[start + i];
        
        /**
         * PERFORMANCE OPTIMIZATION: __ldg()
         * Forces the use of the Read-Only Data Cache (Texture Cache).
         * Since the transition table is static during search, this significantly
         * increases memory bandwidth and reduces L1 cache pressure.
         */
        state = __ldg(&d_table[state * 256 + c]);
        
        // Accumulate matches found at this state
        matches += __ldg(&d_output_counts[state]);
    }

    // Write back the total count for this specific packet
    d_results[tid] = matches;
}

// --- HOST WRAPPERS (C-Interface) ---

/**
 * run_gpu_packet_benchmark: Handles orchestration of GPU resources and execution.
 * * @return Execution time in seconds (Kernel time only, excludes allocation/transfer).
 */
extern "C" double run_gpu_packet_benchmark(const AC_Machine *m, const char *payload, 
                                          long *packet_offsets, int *packet_lengths, 
                                          int num_packets, int loops, long *out_matches) 
{
    
    // Safety check for empty data
    if (num_packets <= 0) return 0.0;

    int *d_table = NULL, *d_output_counts = NULL, *d_packet_lengths = NULL;
    char *d_payload = NULL;
    long *d_packet_offsets = NULL, *d_results = NULL;

    // CUDA Execution Configuration
    int num_threads = 256; // Standard warp-friendly block size
    int num_blocks = (num_packets + num_threads - 1) / num_threads;

    // Calculate total data size for the unified payload buffer
    size_t total_data_size = packet_offsets[num_packets-1] + packet_lengths[num_packets-1];

    // 1. GPU Memory Allocation
    CUDA_CHECK(cudaMalloc(&d_table, m->capacity * 256 * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_output_counts, m->capacity * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_payload, total_data_size));
    CUDA_CHECK(cudaMalloc(&d_packet_offsets, num_packets * sizeof(long)));
    CUDA_CHECK(cudaMalloc(&d_packet_lengths, num_packets * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_results, num_packets * sizeof(long)));

    // 2. Data Transfer (Host to Device)
    CUDA_CHECK(cudaMemcpy(d_table, m->transition_table, m->capacity * 256 * sizeof(int), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_output_counts, m->output_counts, m->capacity * sizeof(int), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_payload, payload, total_data_size, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_packet_offsets, packet_offsets, num_packets * sizeof(long), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_packet_lengths, packet_lengths, num_packets * sizeof(int), cudaMemcpyHostToDevice));

    // 3. Performance Measurement using CUDA Events
    cudaEvent_t start, stop;
    cudaEventCreate(&start); cudaEventCreate(&stop);
    cudaEventRecord(start);

    // Warm-up and Benchmarking loops
    for (int i = 0; i < loops; i++) {
        ac_kernel_packets<<<num_blocks, num_threads>>>(d_table, d_output_counts, d_payload, 
                                                       d_packet_offsets, d_packet_lengths, 
                                                       num_packets, d_results);
    }

    cudaEventRecord(stop);
    cudaEventSynchronize(stop); // Wait for the GPU to finish all work

    float ms = 0;
    cudaEventElapsedTime(&ms, start, stop);

    // 4. Result Retrieval
    long *h_results = (long*)malloc(num_packets * sizeof(long));
    CUDA_CHECK(cudaMemcpy(h_results, d_results, num_packets * sizeof(long), cudaMemcpyDeviceToHost));
    
    // Aggregating results from all packets
    long total = 0;
    for(int i = 0; i < num_packets; i++) {
        total += h_results[i];
    }
    *out_matches = total;

    // 5. Resource Cleanup
    free(h_results);
    CUDA_CHECK(cudaFree(d_table));
    CUDA_CHECK(cudaFree(d_output_counts));
    CUDA_CHECK(cudaFree(d_payload));
    CUDA_CHECK(cudaFree(d_packet_offsets));
    CUDA_CHECK(cudaFree(d_packet_lengths));
    CUDA_CHECK(cudaFree(d_results));
    cudaEventDestroy(start);
    cudaEventDestroy(stop);

    return (double)ms / 1000.0; 
}


/**
 * run_gpu_buffering_benchmark:
 * Implements Asynchronous Double Buffering using CUDA Streams.
 * This technique overlaps Host-to-Device (H2D) transfers with Kernel execution.
 */
extern "C" double run_gpu_buffering_benchmark(const AC_Machine *m, const char *payload, 
                                             long *packet_offsets, int *packet_lengths, 
                                             int num_packets, int loops, long *out_matches,
                                             int threads_per_block) 
{
    if (num_packets <= 0) return 0.0;

    // 1. Setup Resources
    int *d_table, *d_output_counts,*d_packet_lengths;;
    char *d_payload;
    long *d_packet_offsets, *d_results;
    
    size_t total_data_size = packet_offsets[num_packets-1] + packet_lengths[num_packets-1];

    // Allocations (Same as before)
    CUDA_CHECK(cudaMalloc(&d_table, m->capacity * 256 * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_output_counts, m->capacity * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_payload, total_data_size));
    CUDA_CHECK(cudaMalloc(&d_packet_offsets, num_packets * sizeof(long)));
    CUDA_CHECK(cudaMalloc(&d_packet_lengths, num_packets * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_results, num_packets * sizeof(long)));

    // 2. Create CUDA Streams for concurrency
    cudaStream_t stream1, stream2;
    cudaStreamCreate(&stream1);
    cudaStreamCreate(&stream2);

    // Initial Transfer of static data (Table & Counts)
    cudaMemcpy(d_table, m->transition_table, m->capacity * 256 * sizeof(int), cudaMemcpyHostToDevice);
    cudaMemcpy(d_output_counts, m->output_counts, m->capacity * sizeof(int), cudaMemcpyHostToDevice);
    // Offsets and lengths are also needed before starting
    cudaMemcpy(d_packet_offsets, packet_offsets, num_packets * sizeof(long), cudaMemcpyHostToDevice);
    cudaMemcpy(d_packet_lengths, packet_lengths, num_packets * sizeof(int), cudaMemcpyHostToDevice);

    // 3. Define the Split Point (50/50 split)
    int mid = num_packets / 2;
    size_t size_part1 = packet_offsets[mid-1] + packet_lengths[mid-1];
    size_t size_part2 = total_data_size - size_part1;

    cudaEvent_t start, stop;
    cudaEventCreate(&start); cudaEventCreate(&stop);
    cudaEventRecord(start);

    for (int i = 0; i < loops; i++) {
        // --- STREAM 1: Process First Half ---
        // Asynchronous transfer: CPU continues immediately
        cudaMemcpyAsync(d_payload, payload, size_part1, cudaMemcpyHostToDevice, stream1);
        
        // Kernel 1 starts as soon as transfer 1 is done
        int blocks1 = (mid + threads_per_block - 1) / threads_per_block;
        ac_kernel_packets<<<blocks1, threads_per_block, 0, stream1>>>(
            d_table, d_output_counts, d_payload, d_packet_offsets, d_packet_lengths, mid, d_results);

        // --- STREAM 2: Process Second Half ---
        // This transfer happens IN PARALLEL with Kernel 1 execution!
        cudaMemcpyAsync(d_payload + size_part1, payload + size_part1, size_part2, cudaMemcpyHostToDevice, stream2);
        
        // Kernel 2 starts as soon as transfer 2 is done
        int blocks2 = (num_packets - mid + threads_per_block - 1) / threads_per_block;
        ac_kernel_packets<<<blocks2, threads_per_block, 0, stream2>>>(
            d_table, d_output_counts, d_payload, d_packet_offsets + mid, d_packet_lengths + mid, num_packets - mid, d_results + mid);
    }

    // Wait for both streams to finish
    cudaStreamSynchronize(stream1);
    cudaStreamSynchronize(stream2);

    cudaEventRecord(stop);
    cudaEventSynchronize(stop);

    float ms = 0;
    cudaEventElapsedTime(&ms, start, stop);

    // 4. Collect Results
    long *h_results = (long*)malloc(num_packets * sizeof(long));
    cudaMemcpy(h_results, d_results, num_packets * sizeof(long), cudaMemcpyDeviceToHost);
    
    long total = 0;
    for(int i = 0; i < num_packets; i++) total += h_results[i];
    *out_matches = total;

    // 5. Cleanup
    free(h_results);
    cudaFree(d_table); cudaFree(d_output_counts); cudaFree(d_payload);
    cudaFree(d_packet_offsets); cudaFree(d_packet_lengths); cudaFree(d_results);
    cudaStreamDestroy(stream1); cudaStreamDestroy(stream2);
    cudaEventDestroy(start); cudaEventDestroy(stop);

    return (double)ms / 1000.0;
}