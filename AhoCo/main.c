#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <omp.h>
#include "ac.h"
#include "utils.h"
#include "gpu_ac.h" 
#include <cuda_runtime.h>

/**
 * Default configurations for the NIDS Benchmark
 */
#define DEFAULT_PATTERNS "./Rules/patterns.txt"
#define DEFAULT_DATA     "./Data/data.bin"
#define DEFAULT_LOOPS    1
#define DEFAULT_THREADS  4
#define PACKET_SIZE      1500 // Simulated MTU size in bytes
#define GPU_BLOCK_SIZE   256  // Standard threads per block for Ampere/RTX 3060

int main(int argc, char** argv) {
    
    // Parse command line arguments
    const char* mode          = (argc >= 2) ? argv[1] : "cpu";
    int num_threads           = (argc >= 3) ? atoi(argv[2]) : DEFAULT_THREADS;
    int loops                 = (argc >= 4) ? atoi(argv[3]) : DEFAULT_LOOPS;
    const char* patterns_path = (argc >= 5) ? argv[4] : DEFAULT_PATTERNS;
    const char* data_path     = (argc >= 6) ? argv[5] : DEFAULT_DATA;
    
    printf("==================================================\n");
    printf("      Aho-Corasick NIDS Benchmark - Thesis      \n");
    printf("==================================================\n");

    // 1. Initialize Automaton
    AC_Machine *nids = ac_create();
    load_patterns(nids, patterns_path); 
    ac_finalize(nids); 

    // 2. Load Payload
    long data_len;
    char* payload = load_file(data_path, &data_len);

    // 3. Prepare Packet structures
    int num_packets = (int)(data_len / PACKET_SIZE);
    if (num_packets == 0) num_packets = 1;


     int gpu_threads_per_block = (argc >= 7) ? atoi(argv[6]) : 256;
    int gpu_manual_blocks     = (argc >= 8) ? atoi(argv[7]) : 0;
    int threads_per_block = gpu_threads_per_block;
    int num_blocks = (gpu_manual_blocks > 0) ? gpu_manual_blocks : (num_packets + threads_per_block - 1) / threads_per_block;

    long *offsets = (long*)malloc(num_packets * sizeof(long));
    int *lengths = (int*)malloc(num_packets * sizeof(int));

    for(int i = 0; i < num_packets; i++) {
        offsets[i] = (long)i * PACKET_SIZE;
        lengths[i] = (i == num_packets - 1) ? (int)(data_len - offsets[i]) : PACKET_SIZE;
    }

    double time_total = 0;
    long matches = 0;
    unsigned long long total_bytes = (unsigned long long)data_len * loops;

    // 4. Execution Logic
    if (strcmp(mode, "gpu") == 0) {
        /* --- MODE GPU CLASSIQUE (Synchrone) --- */
        print_gpu_specs();
        printf("\n--- Mode: Standard GPU (Synchronous) ---\n");
        time_total = run_gpu_packet_benchmark(nids, payload, offsets, lengths, 
                                              num_packets, loops, &matches);
                
    } 
    else if (strcmp(mode, "gpu_async") == 0) {
        /* --- MODE GPU DOUBLE BUFFERING (Asynchrone) --- */
        print_gpu_specs();
        printf("\n--- Mode: GPU Double Buffering (Asynchronous Streams) ---\n");
        time_total = run_gpu_buffering_benchmark(nids, payload, offsets, lengths, 
                                                num_packets, loops, &matches, 
                                                threads_per_block);
             
    } else {
        printf("\n--- Starting OpenMP CPU Benchmark ---\n");
        printf("Parallelism : %d Threads\n", num_threads);
        
        omp_set_num_threads(num_threads);
        double start_time = omp_get_wtime();

        for (int l = 0; l < loops; l++) {
            long loop_matches = 0;
            #pragma omp parallel reduction(+:loop_matches)
            {
                int tid = omp_get_thread_num();
                int nthreads = omp_get_num_threads();
                for (int i = tid; i < num_packets; i += nthreads) {
                    int state = 0;
                    long start_off = offsets[i];
                    int p_len = lengths[i];
                    for (int j = 0; j < p_len; j++) {
                        unsigned char ch = (unsigned char)payload[start_off + j];
                        state = nids->transition_table[state * 256 + ch];
                        loop_matches += nids->output_counts[state];
                    }
                }
            }
            matches += loop_matches;
        }
        double end_time = omp_get_wtime();
        time_total = end_time - start_time;
    }

    // 5. Final Statistics
    double throughput_gbps = ((double)total_bytes * 8) / (time_total * 1000000000.0);

    printf("\n================ RESULT SUMMARY ================\n");
    printf("Execution Mode   : %s\n", mode);
    printf("Total Matches    : %ld\n", matches);
    printf("Time Elapsed     : %.4f seconds\n", time_total);
    printf("Throughput       : %.2f Gbps\n", throughput_gbps);
    printf("================================================\n");

    // Cleanup
    free(offsets); 
    free(lengths); 
    ac_free(nids);
    cudaFreeHost(payload);
    
    return 0;
}