#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "../ac.h"
#include "ac_classic.h"
#include "cuda_utils.h"
#include "payload.h" // Ajout du header Mbuf

__global__ void ac_classic_kernel(
    const int * __restrict__ d_table, 
    const int * __restrict__ d_output_counts, 
    const char * __restrict__ d_payload, 
    const unsigned long * __restrict__ d_packet_start, 
    const int * __restrict__ d_packet_lengths, 
    int num_packets, 
    long * d_results) 
{
    // Le kernel reste parfaitement identique !
    long tid = (long)blockIdx.x * blockDim.x + threadIdx.x;
    if (tid >= num_packets) return;

    unsigned long start = d_packet_start[tid];
    int len = d_packet_lengths[tid];
    
    int state = 0; 
    long matches = 0;

    for (int i = 0; i < len; i++) {
        unsigned char c = (unsigned char)d_payload[start + i];
        state = __ldg(&d_table[state * 256 + c]);
        matches += __ldg(&d_output_counts[state]);
    }

    d_results[tid] = matches;
}

extern "C" {
// NOUVELLE SIGNATURE AVEC MbufPool
double run_classic_packet_benchmark(const AC_Machine *m, MbufPool *pool, int loops, long *out_matches) {
    int num_packets = pool->packet_count;
    if (num_packets <= 0) return 0.0;

    size_t total_data_size = pool->total_bytes;

    // 1. Traduction rapide des Mbufs en tableaux GPU
    unsigned long *h_packet_start = (unsigned long *)malloc(num_packets * sizeof(unsigned long));
    int *h_packet_lengths = (int *)malloc(num_packets * sizeof(int));
    
    for(int i = 0; i < num_packets; i++) {
        h_packet_start[i] = (unsigned long)((char*)pool->mbuf_array[i].buf_addr - (char*)pool->mempool_data);
        h_packet_lengths[i] = pool->mbuf_array[i].data_len;
    }

    // Le payload est déjà en Pinned Memory
    char *pinned_payload = (char *)pool->mempool_data;

    int *d_table, *d_output_counts, *d_packet_lengths;
    char *d_payload;
    unsigned long *d_packet_start;
    long *d_results;

    int num_threads = 256; // Par défaut
    int num_blocks = (num_packets + num_threads - 1) / num_threads;

    CUDA_CHECK(cudaMalloc(&d_table, m->capacity * 256 * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_output_counts, m->capacity * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_payload, total_data_size));
    CUDA_CHECK(cudaMalloc(&d_packet_start, num_packets * sizeof(unsigned long)));
    CUDA_CHECK(cudaMalloc(&d_packet_lengths, num_packets * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_results, num_packets * sizeof(long)));

    CUDA_CHECK(cudaMemcpy(d_table, m->transition_table, m->capacity * 256 * sizeof(int), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_output_counts, m->output_counts, m->capacity * sizeof(int), cudaMemcpyHostToDevice));
    
    // On copie tout le payload d'un coup (C'est le mode "Classic")
    CUDA_CHECK(cudaMemcpy(d_payload, pinned_payload, total_data_size, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_packet_start, h_packet_start, num_packets * sizeof(unsigned long), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_packet_lengths, h_packet_lengths, num_packets * sizeof(int), cudaMemcpyHostToDevice));

    cudaEvent_t start_ev, stop_ev;
    cudaEventCreate(&start_ev); cudaEventCreate(&stop_ev);
    
    // --- DÉMARRAGE DU CHRONO ---
    cudaEventRecord(start_ev);

    for (int i = 0; i < loops; i++) {
        ac_classic_kernel<<<num_blocks, num_threads>>>(d_table, d_output_counts, d_payload, 
                                                       d_packet_start, d_packet_lengths, 
                                                       num_packets, d_results);
    }

    cudaEventRecord(stop_ev);
    cudaEventSynchronize(stop_ev); 
    // --- FIN DU CHRONO ---
    
    float ms = 0;
    cudaEventElapsedTime(&ms, start_ev, stop_ev);

    long *h_results = (long*)malloc(num_packets * sizeof(long));
    CUDA_CHECK(cudaMemcpy(h_results, d_results, num_packets * sizeof(long), cudaMemcpyDeviceToHost));
    
    long total = 0;
    for(int i = 0; i < num_packets; i++) total += h_results[i];
    *out_matches = total;

    // Nettoyage
    free(h_results);
    free(h_packet_start); 
    free(h_packet_lengths);
    CUDA_CHECK(cudaFree(d_table)); CUDA_CHECK(cudaFree(d_output_counts));
    CUDA_CHECK(cudaFree(d_payload)); CUDA_CHECK(cudaFree(d_packet_start));
    CUDA_CHECK(cudaFree(d_packet_lengths)); CUDA_CHECK(cudaFree(d_results));
    cudaEventDestroy(start_ev); cudaEventDestroy(stop_ev);

    // Divisé par loops pour avoir le temps d'une seule exécution !
    return ((double)ms / 1000.0) / loops; 
}
}