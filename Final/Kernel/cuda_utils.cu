#include "cuda_utils.h"

void print_gpu_specs() {
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);
    if (deviceCount == 0) {
        printf("No CUDA devices found.\n");
        return;
    }

    cudaDeviceProp props;
    cudaGetDeviceProperties(&props, 0); // Assuming device 0

    printf("\n==================================================");
    printf("\n   🚀 GPU HARDWARE SPECIFICATIONS");
    printf("\n==================================================");
    printf("\n  GPU Name              : %s", props.name);
    printf("\n  Compute Capability    : %d.%d", props.major, props.minor);
    printf("\n  Total Global Memory   : %.2f GB", (float)props.totalGlobalMem / (1024.0 * 1024.0 * 1024.0));
    printf("\n  Multiprocessors (SM)  : %d", props.multiProcessorCount);
    printf("\n  L2 Cache Size         : %d KB", props.l2CacheSize / 1024);
    printf("\n==================================================\n\n");
}