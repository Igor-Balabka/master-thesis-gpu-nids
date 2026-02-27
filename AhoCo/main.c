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

    if (strcmp(mode, "gpu") == 0) {
        printf("\n--- 3. Starting Benchmark (CUDA GPU) ---\n");
        // On appelle la fonction C++ CUDA
        time_total = run_gpu_benchmark(nids, payload, data_len, loops, &matches);
        
    } else {
        printf("\n--- 3. Starting Benchmark (OpenMP CPU Data-Parallel) ---\n");
        omp_set_num_threads(num_threads);
        double start_time = omp_get_wtime();

        for (int i = 0; i < loops; i++) {
            long loop_matches = 0;

            // On parallélise le découpage du fichier (comme les blocs CUDA !)
            #pragma omp parallel reduction(+:loop_matches)
            {
                int tid = omp_get_thread_num();
                int nthreads = omp_get_num_threads();

                // Calcul des frontières (Chunks) pour ce thread
                long chunk_size = (data_len + nthreads - 1) / nthreads;
                long start = tid * chunk_size;
                long end = start + chunk_size;
                if (end > data_len) end = data_len;

                if (start < data_len) {
                    int current_state = 0;
                    long local_matches = 0;
                    
                    // Ce thread ne lit QUE sa portion des 4 Go
                    for (long j = start; j < end; ++j) {
                        unsigned char ch = (unsigned char)payload[j];
                        current_state = nids->transition_table[current_state * 256 + ch];
                        if (nids->output_counts[current_state] > 0) {
                            local_matches += nids->output_counts[current_state];
                        }
                    }
                    loop_matches += local_matches;
                }
            }
            matches += loop_matches;
        }

        double end_time = omp_get_wtime();
        time_total = end_time - start_time;
    }

    // 5. Statistics
    double throughput_mbps = ((double)total_bytes * 8) / (time_total * 1000000);

    printf("--------------------------------\n");
    printf("Mode             : %s\n", mode);
    printf("Time elapsed     : %.4f seconds\n", time_total);
    printf("Total matches    : %ld\n", matches);
    printf("Throughput       : %.2f Mbps\n", throughput_mbps);
    printf("--------------------------------\n");

    free(payload);
    ac_free(nids);
    return 0;
}