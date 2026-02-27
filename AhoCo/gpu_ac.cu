#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "ac.h"
#include "gpu_ac.h"

// Macro pour vérifier les erreurs CUDA facilement
#define CUDA_CHECK(call) \
    do { \
        cudaError_t err = call; \
        if (err != cudaSuccess) { \
            fprintf(stderr, "CUDA Error: %s at line %d\n", cudaGetErrorString(err), __LINE__); \
            exit(EXIT_FAILURE); \
        } \
    } while(0)


// --- 1. LE KERNEL GPU ---
// On remplace les int par des long pour supporter les fichiers > 2 Go
__global__ void ac_kernel_dfa(int *d_table, 
                              int *d_output_counts, 
                              char *d_payload, 
                              long data_len, // <-- CORRIGÉ
                              long *d_results) 
{
    // L'ID du thread doit aussi être en long au cas où on utilise énormément de threads
    long tid = blockIdx.x * blockDim.x + threadIdx.x;
    long total_threads = gridDim.x * blockDim.x;

    if (tid >= total_threads) return;

    // Découpage du fichier pour ce thread (en long !)
    long chunk_size = (data_len + total_threads - 1) / total_threads;
    long start = tid * chunk_size;
    long end = start + chunk_size;
    if (end > data_len) end = data_len;

    if (start >= data_len) return;

    int state = 0; 
    long matches = 0;

    // La boucle parcourt des milliards d'octets, i doit être un long
    for (long i = start; i < end; i++) {
        unsigned char c = (unsigned char)d_payload[i];
        state = d_table[state * 256 + c];

        // if (d_output_counts[state] > 0) {
        //     matches += d_output_counts[state];
        // }
    
        //Optimization : From 38 gbps to 64gbps
        state = __ldg(&d_table[state * 256 + c]);
if (__ldg(&d_output_counts[state]) > 0) {
    matches += __ldg(&d_output_counts[state]);
}

    }

    d_results[tid] = matches;
}


extern "C" double run_gpu_benchmark(const AC_Machine *m, const char *payload, long data_len, int loops, long *out_matches) 
{
    int *d_table = NULL;
    int *d_output_counts = NULL;
    char *d_payload = NULL;
    long *d_results = NULL;

    int num_threads = 256;
    int num_blocks = 2048; 
    int total_threads = num_threads * num_blocks;

    size_t table_size = m->capacity * ALPHABET_SIZE * sizeof(int);

    CUDA_CHECK(cudaMalloc((void**)&d_table, table_size));
    CUDA_CHECK(cudaMalloc((void**)&d_output_counts, m->capacity * sizeof(int)));
    CUDA_CHECK(cudaMalloc((void**)&d_payload, data_len));
    CUDA_CHECK(cudaMalloc((void**)&d_results, total_threads * sizeof(long)));

    CUDA_CHECK(cudaMemcpy(d_table, m->transition_table, table_size, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_output_counts, m->output_counts, m->capacity * sizeof(int), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_payload, payload, data_len, cudaMemcpyHostToDevice));

    CUDA_CHECK(cudaMemset(d_results, 0, total_threads * sizeof(long)));

    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    cudaEventRecord(start);

    for (int i = 0; i < loops; i++) {
        ac_kernel_dfa<<<num_blocks, num_threads>>>(d_table, d_output_counts, d_payload, data_len, d_results);
    }

    cudaEventRecord(stop);
    CUDA_CHECK(cudaEventSynchronize(stop)); 

    float ms = 0;
    cudaEventElapsedTime(&ms, start, stop);
    double seconds = ms / 1000.0;

    long *h_results = (long*)malloc(total_threads * sizeof(long));
    CUDA_CHECK(cudaMemcpy(h_results, d_results, total_threads * sizeof(long), cudaMemcpyDeviceToHost));
    
    long total_matches = 0;
    for (int i = 0; i < total_threads; i++) {
        total_matches += h_results[i];
    }
    *out_matches = total_matches; 

    cudaFree(d_table);
    cudaFree(d_output_counts);
    cudaFree(d_payload);
    cudaFree(d_results);
    free(h_results);
    cudaEventDestroy(start);
    cudaEventDestroy(stop);

    return seconds;
}