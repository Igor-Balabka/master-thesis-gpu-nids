#include "cuda_utils.h"
extern "C" {
/**
 * Utility function to display the hardware characteristics of the GPU.
 * This is crucial for verifying the available L2 cache and SM count
 * before running performance benchmarks.
 */
void print_gpu_specs()
{
    int deviceCount;
    // Check how many CUDA-capable GPUs are available
    CUDA_CHECK(cudaGetDeviceCount(&deviceCount));

    if (deviceCount == 0)
    {
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
    printf("\n  Shared Mem per Block  : %zu KB", props.sharedMemPerBlock / 1024);
    printf("\n  L2 Cache Size         : %d KB", props.l2CacheSize / 1024);
    printf("\n==================================================\n\n");
}

void prepare_packet_metadata(MbufPool *pool, unsigned long *h_packet_start, int *h_packet_lengths)
{
    for (int i = 0; i < pool->packet_count; i++)
    {
        h_packet_start[i] = (unsigned long)((char *)pool->mbuf_array[i].buf_addr - (char *)pool->mempool_data);
        h_packet_lengths[i] = pool->mbuf_array[i].data_len;
    }
}

void cleanup_gpu(int *d_table, int *d_output_counts, char *d_payload,
                 unsigned long *d_packet_start, int *d_packet_lengths,
                 long *d_results, cudaStream_t *streams, int n_slots)
{
    cudaFree(d_table);
    cudaFree(d_output_counts);
    cudaFree(d_payload);
    cudaFree(d_packet_start);
    cudaFree(d_packet_lengths);
    cudaFree(d_results);

    if (streams)
    {
        for (int i = 0; i < n_slots; i++)
            cudaStreamDestroy(streams[i]);
        free(streams);
    }
}



}