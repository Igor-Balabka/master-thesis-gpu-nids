#ifndef CUDA_UTILS_H
#define CUDA_UTILS_H

#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include "../payload.h"



/**
 * Prints hardware details of the available GPU.
 * Useful for logging and ensuring the benchmark runs on the correct device.
 */
#ifdef __cplusplus
extern "C" {
#endif

void print_gpu_specs();

void prepare_packet_metadata(MbufPool *pool, unsigned long *h_packet_start, int *h_packet_lengths);

void cleanup_gpu(int *d_table, int *d_output_counts, char *d_payload,
                 unsigned long *d_packet_start, int *d_packet_lengths,
                 long *d_results, cudaStream_t *streams, int n_slots);

#ifdef __cplusplus
}
#endif

/**
 * Macro to check for CUDA errors.
 * It wraps any CUDA API call and checks the return code.
 * If an error occurs, it prints the error message, the file name,
 * and the line number, then stops the program.
 */
#define CUDA_CHECK(call)                                          \
    do                                                            \
    {                                                             \
        cudaError_t err = call;                                   \
        if (err != cudaSuccess)                                   \
        {                                                         \
            fprintf(stderr, "CUDA Error: %s at %s:%d\n",          \
                    cudaGetErrorString(err), __FILE__, __LINE__); \
            exit(EXIT_FAILURE);                                   \
        }                                                         \
    } while (0)

#endif