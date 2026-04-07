#include "cuda_utils.h"

void print_gpu_specs() {
    int deviceCount;
    CUDA_CHECK(cudaGetDeviceCount(&deviceCount));
    
    if (deviceCount == 0) {
        printf("No CUDA devices found.\n");
        return;
    }

    cudaDeviceProp props;
    CUDA_CHECK(cudaGetDeviceProperties(&props, 0)); 

    printf("\n==================================================");
    printf("\n   🚀 GPU HARDWARE SPECIFICATIONS");
    printf("\n==================================================");
    printf("\n  GPU Name              : %s", props.name);
    printf("\n  Compute Capability    : %d.%d", props.major, props.minor);
    printf("\n  Total Global Memory   : %.2f GB", (float)props.totalGlobalMem / (1024.0 * 1024.0 * 1024.0));
    printf("\n  Multiprocessors (SM)  : %d", props.multiProcessorCount);
    printf("\n  Shared Mem per Block  : %zu KB", props.sharedMemPerBlock / 1024); // Ajout intéressant
    printf("\n  L2 Cache Size         : %d KB", props.l2CacheSize / 1024);
    printf("\n==================================================\n\n");
}