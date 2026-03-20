#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include "cuda_utils.h"





#define CUDA_CHECK(call) \
    do { \
        cudaError_t err = call; \
        if (err != cudaSuccess) { \
            fprintf(stderr, "CUDA Error: %s at line %d\n", cudaGetErrorString(err), __LINE__); \
            exit(EXIT_FAILURE); \
        } \
    } while(0)


    void print_gpu_specs(){
        int device;
        cprintf("\n==================================================");
    printf("\n   🚀 GPU HARDWARE SPECIFICATIONS");
    printf("\n==================================================");

    printf("\n[General Information]");
    printf("\n  GPU Name              : %s", props.name);
    printf("\n  Compute Capability    : %d.%d", props.major, props.minor);
    printf("\n  Total Global Memory   : %.2f GB", (float)props.totalGlobalMem / (1024.0 * 1024.0 * 1024.0));

    printf("\n\n[Compute Power]");
    printf("\n  Multiprocessors (SM)  : %d", props.multiProcessorCount);
    printf("\n  Warp Size             : %d threads", props.warpSize);
    printf("\n  Max Threads per SM    : %d", props.maxThreadsPerMultiprocessor);

    printf("\n\n[Memory Hierarchy]");
    printf("\n  Shared Mem per Block (L1 Cache size)  : %zu KB", props.sharedMemPerBlock / 1024);
    printf("\n  Constant Memory       : %zu KB", props.totalConstMem / 1024);
    printf("\n  L2 Cache Size         : %d KB", props.l2CacheSize / 1024);

    printf("\n\n[Execution Limits]");
    printf("\n  Max Threads per Block : %d", props.maxThreadsPerBlock);
    printf("\n  Max Grid Dimensions   : [%d, %d, %d]", 
           props.maxGridSize[0], props.maxGridSize[1], props.maxGridSize[2]);
    printf("\n  Max Block Dimensions  : [%d, %d, %d]", 
           props.maxThreadsDim[0], props.maxThreadsDim[1], props.maxThreadsDim[2]);
    
    printf("\n==================================================\n\n");}