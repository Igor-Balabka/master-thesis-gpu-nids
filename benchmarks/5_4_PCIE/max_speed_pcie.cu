#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <cuda_runtime.h>

#define TEST_DURATION 20.0  // 20 seconds per test configuration
#define DATA_SIZE (1ULL * 1024 * 1024 * 1024)

// Macro to check CUDA errors and exit on failure
#define CUDA_CHECK(call) \
    do { \
        cudaError_t err = call; \
        if (err != cudaSuccess) { \
            fprintf(stderr, "CUDA Error: %s\n", cudaGetErrorString(err)); \
            exit(EXIT_FAILURE); \
        } \
    } while (0)

// Function to benchmark Host-to-Device memory copy scaling across multiple streams
double run_h2d_scaling_test(int num_streams, bool use_pinned, void *h_data) {
    cudaStream_t *streams = (cudaStream_t*)malloc(num_streams * sizeof(cudaStream_t));
    void **d_buffers = (void**)malloc(num_streams * sizeof(void*));
    void **h_buffers = (void**)malloc(num_streams * sizeof(void*));

    size_t chunk_size = DATA_SIZE / num_streams;

    // Initialize streams, device memory, and host buffers (pageable or pinned)
    for (int i = 0; i < num_streams; i++) {
        CUDA_CHECK(cudaStreamCreateWithFlags(&streams[i], cudaStreamNonBlocking));
        CUDA_CHECK(cudaMalloc(&d_buffers[i], chunk_size));

        if (use_pinned) {
            CUDA_CHECK(cudaHostAlloc(&h_buffers[i], chunk_size, cudaHostAllocDefault));
            memcpy(h_buffers[i], (char*)h_data + (i * chunk_size), chunk_size);
        } else {
            h_buffers[i] = malloc(chunk_size);
            memcpy(h_buffers[i], (char*)h_data + (i * chunk_size), chunk_size);
        }
    }

    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    double elapsed = 0.0;
    unsigned long long iterations = 0;

    // Run benchmark loop for the specified test duration
    while (elapsed < TEST_DURATION) {
        // Asynchronously copy chunks from host to device across all streams
        for (int i = 0; i < num_streams; i++) {
            CUDA_CHECK(cudaMemcpyAsync(d_buffers[i], h_buffers[i], chunk_size, cudaMemcpyHostToDevice, streams[i]));
        }
        
        // Synchronize all streams to complete the batch transfer
        for (int i = 0; i < num_streams; i++) {
            CUDA_CHECK(cudaStreamSynchronize(streams[i]));
        }

        iterations++;
        clock_gettime(CLOCK_MONOTONIC, &end);
        elapsed = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
    }

    // Calculate throughput in Gbps
    double total_bits = (double)iterations * DATA_SIZE * 8.0;
    double throughput_gbps = total_bits / (elapsed * 1e9);

    // Free all allocated resources
    for (int i = 0; i < num_streams; i++) {
        cudaFree(d_buffers[i]);
        if (use_pinned) cudaFreeHost(h_buffers[i]); else free(h_buffers[i]);
        cudaStreamDestroy(streams[i]);
    }
    free(streams); free(d_buffers); free(h_buffers);

    return throughput_gbps;
}

int main() {
    // Allocate global host data buffer
    void *h_data = malloc(DATA_SIZE);
    if (!h_data) {
        fprintf(stderr, "Host memory allocation error.\n");
        return 1;
    }
    memset(h_data, 0xAB, DATA_SIZE);

    int stream_counts[] = {1, 2, 4, 8, 16};
    int num_options = sizeof(stream_counts) / sizeof(stream_counts[0]);

    // Test scaling across different stream counts for pageable and pinned memory
    for (int i = 0; i < num_options; i++) {
        int n_streams = stream_counts[i];
        
        double bw_pageable = run_h2d_scaling_test(n_streams, false, h_data);
        double bw_pinned = run_h2d_scaling_test(n_streams, true, h_data);

        // Clean output format for Bash script parsing
        printf("RESULT:%d,%.2f,%.2f\n", n_streams, bw_pageable, bw_pinned);
    }

    free(h_data);
    return 0;
}