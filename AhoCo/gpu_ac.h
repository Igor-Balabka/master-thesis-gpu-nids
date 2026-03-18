#ifndef GPU_AC_H
#define GPU_AC_H

#include "ac.h"

/**
 * The 'extern "C"' block is essential here. 
 * Since CUDA (.cu) files are compiled by NVCC (a C++ compiler), 
 * we must prevent 'name mangling' so that the standard C linker 
 * can find and call our GPU functions from main.c.
 */
#ifdef __cplusplus
extern "C" {
#endif


void print_gpu_specs();


/**
 * run_gpu_packet_benchmark:
 * Orchestrates the Aho-Corasick search on the GPU using a packet-aware approach.
 * * @param m              Pointer to the finalized AC_Machine (DFA) on Host.
 * @param payload        Pointer to the continuous buffer of network data on Host.
 * @param packet_offsets Array of starting positions for each packet in the payload.
 * @param packet_lengths Array of lengths for each individual packet.
 * @param num_packets    Total number of packets to process.
 * @param loops          Number of iterations (for benchmarking stability).
 * @param out_matches    Pointer to store the total sum of matches found.
 * * @return The execution time of the GPU kernels in seconds.
 */
double run_gpu_packet_benchmark(const AC_Machine *m, const char *payload, 
                                long *packet_offsets, int *packet_lengths, 
                                int num_packets, int loops, long *out_matches);

double run_gpu_buffering_benchmark(const AC_Machine *m, const char *payload, 
                                  long *packet_offsets, int *packet_lengths, 
                                  int num_packets, int loops, long *out_matches,
                                  int threads_per_block);


#ifdef __cplusplus
}
#endif

#endif