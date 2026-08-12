// GPU engine header file for CUDA acceleration
#ifndef GPU_ENGINE_H
#define GPU_ENGINE_H

#include "config.h"
#include "ac.h"
#include "payload.h"

// Allow C++ functions to be called safely from C code
#ifdef __cplusplus
extern "C" {
#endif

// Initialize the DFA on the GPU device and allocate memory
void gpu_init_dfa(const AC_Automata *m);

// Free all GPU memory used by the DFA
void gpu_free_dfa(void);

// Check if a specific CUDA stream has finished its work (non-blocking)
int gpu_is_stream_ready(int stream_idx);

// Collect matches found by a stream that just finished
unsigned long long gpu_collect_stream_matches(int stream_idx);

// Submit a batch asynchronously (returns immediately without blocking the CPU)
void gpu_process_batch_async_submit(const char *h_packet_data, const uint32_t *h_lengths, uint32_t num_pkts, int stream_idx);

// Wait for all GPU streams to finish at the very end of the program
void gpu_synchronize_all(void);

// Print out GPU hardware specifications
void print_gpu_specs(void);

// Benchmark function to process packets on the GPU
double run_classic_packet_benchmark(const AC_Automata *m, const MbufPool *pool, int loops, long *out_matches);

#ifdef __cplusplus
}
#endif

#endif // GPU_ENGINE_H