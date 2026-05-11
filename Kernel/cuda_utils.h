#ifndef CUDA_UTILS_H
#define CUDA_UTILS_H

#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>



/**
 * Prints hardware details of the available GPU.
 * Useful for logging and ensuring the benchmark runs on the correct device.
 */
#ifdef __cplusplus
extern "C" {
#endif

void print_gpu_specs();

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