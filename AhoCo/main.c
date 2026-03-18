#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <omp.h>
#include "ac.h"
#include "utils.h"
#include "gpu_ac.h" 

#define DEFAULT_PATTERNS "./Rules/patterns.txt"
#define DEFAULT_DATA     "./Data/data.bin"
#define DEFAULT_LOOPS    1
#define DEFAULT_THREADS  4
#define PACKET_SIZE      1500 // Simulation MTU

int main(int argc, char** argv) {
    
    const char* mode          = (argc >= 2) ? argv[1] : "cpu";
    int num_threads           = (argc >= 3) ? atoi(argv[2]) : DEFAULT_THREADS;
    int loops                 = (argc >= 4) ? atoi(argv[3]) : DEFAULT_LOOPS;
    const char* patterns_path = (argc >= 5) ? argv[4] : DEFAULT_PATTERNS;
    const char* data_path     = (argc >= 6) ? argv[5] : DEFAULT_DATA;
    
    printf("--- Execution Setup ---\n");
    printf("Mode           : %s\n", mode);
    printf("Threads (CPU)  : %d\n", num_threads);
    printf("Loops          : %d\n", loops);
    printf("Patterns file  : %s\n", patterns_path);
    printf("-----------------------\n");

    AC_Machine *nids = ac_create();
    load_patterns(nids, patterns_path); 
    ac_finalize(nids);

    long data_len;
    char* payload = load_file(data_path, &data_len);

    double time_total = 0;
    long matches = 0;
    unsigned long long total_bytes = (unsigned long long)data_len * loops;

    // --- Préparation des structures de paquets (commune au CPU et GPU) ---
    int num_packets = data_len / PACKET_SIZE;
    if (num_packets == 0) num_packets = 1;

    long *offsets = (long*)malloc(num_packets * sizeof(long));
    int *lengths = (int*)malloc(num_packets * sizeof(int));

    for(int i = 0; i < num_packets; i++) {
        offsets[i] = (long)i * PACKET_SIZE;
        if (i == num_packets - 1) {
            lengths[i] = (int)(data_len - offsets[i]);
        } else {
            lengths[i] = PACKET_SIZE;
        }
    }

    if (strcmp(mode, "gpu") == 0) {
        printf("\n--- 3. Starting Benchmark (CUDA GPU - Packet Mode) ---\n");
        // CORRECTION : On récupère le temps de retour
        time_total = run_gpu_packet_benchmark(nids, payload, offsets, lengths, num_packets, loops, &matches);
                
    } else {
        printf("\n--- 3. Starting Benchmark (OpenMP CPU - Packet Mode) ---\n");
        omp_set_num_threads(num_threads);
        double start_time = omp_get_wtime();

        for (int l = 0; l < loops; l++) {
            long loop_matches = 0;

            // Parallélisation au niveau des paquets pour éviter les pertes de matches
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

    // 5. Statistics (Gbps est plus parlant pour ton projet)
    double throughput_gbps = ((double)total_bytes * 8) / (time_total * 1000000000.0);

    printf("--------------------------------\n");
    printf("Mode             : %s\n", mode);
    printf("Time elapsed     : %.4f seconds\n", time_total);
    printf("Total matches    : %ld\n", matches);
    printf("Throughput       : %.2f Gbps\n", throughput_gbps);
    printf("--------------------------------\n");

    // Nettoyage
    free(offsets);
    free(lengths);
    // free(payload); // Utilise cudaFreeHost(payload) si tu passes en Pinned Memory plus tard
    free(payload);
    ac_free(nids);
    return 0;
}