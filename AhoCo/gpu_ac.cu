#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "ac.h"
#include "gpu_ac.h"

// Macro pour vérifier les erreurs CUDA
#define CUDA_CHECK(call) \
    do { \
        cudaError_t err = call; \
        if (err != cudaSuccess) { \
            fprintf(stderr, "CUDA Error: %s at line %d\n", cudaGetErrorString(err), __LINE__); \
            exit(EXIT_FAILURE); \
        } \
    } while(0)

// --- KERNEL PRINCIPAL (Un paquet par thread) ---
__global__ void ac_kernel_packets(int *d_table, 
                                  int *d_output_counts, 
                                  char *d_payload, 
                                  long *d_packet_offsets, 
                                  int *d_packet_lengths,  
                                  int num_packets, 
                                  long *d_results) 
{
    long tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid >= num_packets) return;

    long start = d_packet_offsets[tid];
    int len = d_packet_lengths[tid];
    
    int state = 0; 
    long matches = 0;

    for (int i = 0; i < len; i++) {
        unsigned char c = (unsigned char)d_payload[start + i];
        // Utilisation de __ldg pour passer par le cache Read-Only (Gain massif de BP)
        state = __ldg(&d_table[state * 256 + c]);
        matches += __ldg(&d_output_counts[state]);
    }

    d_results[tid] = matches;
}

/* * ANCIEN KERNEL (Stream-based) mis en commentaire pour le moment.
 * Utile pour comparer la performance pure vs la précision paquet.
 * __global__ void ac_kernel_dfa(int *d_table, ...) { ... } 
*/

extern "C" double run_gpu_packet_benchmark(const AC_Machine *m, const char *payload, 
                                          long *packet_offsets, int *packet_lengths, 
                                          int num_packets, int loops, long *out_matches) 
{
    if (num_packets <= 0) return 0.0;

    int *d_table = NULL, *d_output_counts = NULL, *d_packet_lengths = NULL;
    char *d_payload = NULL;
    long *d_packet_offsets = NULL, *d_results = NULL;

    // Configuration des blocs
    int num_threads = 256;
    int num_blocks = (num_packets + num_threads - 1) / num_threads;

    // Calcul de la taille totale des données pour le memcpy
    size_t total_data_size = packet_offsets[num_packets-1] + packet_lengths[num_packets-1];

    // Allocations GPU
    CUDA_CHECK(cudaMalloc(&d_table, m->capacity * 256 * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_output_counts, m->capacity * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_payload, total_data_size));
    CUDA_CHECK(cudaMalloc(&d_packet_offsets, num_packets * sizeof(long)));
    CUDA_CHECK(cudaMalloc(&d_packet_lengths, num_packets * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_results, num_packets * sizeof(long)));

    // Transferts vers le GPU
    CUDA_CHECK(cudaMemcpy(d_table, m->transition_table, m->capacity * 256 * sizeof(int), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_output_counts, m->output_counts, m->capacity * sizeof(int), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_payload, payload, total_data_size, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_packet_offsets, packet_offsets, num_packets * sizeof(long), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_packet_lengths, packet_lengths, num_packets * sizeof(int), cudaMemcpyHostToDevice));

    // Chronométrage précis
    cudaEvent_t start, stop;
    cudaEventCreate(&start); cudaEventCreate(&stop);
    cudaEventRecord(start);

    for (int i = 0; i < loops; i++) {
        ac_kernel_packets<<<num_blocks, num_threads>>>(d_table, d_output_counts, d_payload, 
                                                       d_packet_offsets, d_packet_lengths, 
                                                       num_packets, d_results);
    }

    cudaEventRecord(stop);
    cudaEventSynchronize(stop);

    float ms = 0;
    cudaEventElapsedTime(&ms, start, stop);

    // Récupération des résultats
    long *h_results = (long*)malloc(num_packets * sizeof(long));
    CUDA_CHECK(cudaMemcpy(h_results, d_results, num_packets * sizeof(long), cudaMemcpyDeviceToHost));
    
    long total = 0;
    for(int i = 0; i < num_packets; i++) {
        total += h_results[i];
    }
    *out_matches = total;

    // --- LIBÉRATION DES RESSOURCES ---
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

/* extern "C" double run_gpu_benchmark(...) { 

}
*/