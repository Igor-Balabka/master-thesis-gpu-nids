#include <stdio.h>
#include <stdlib.h>
#include <omp.h>
#include "ac.h"
#include "utils.h"

// --- Default Settings ---
#define DEFAULT_PATTERNS "Rules/patterns.txt"
#define DEFAULT_DATA     "Data/data.bin"
#define DEFAULT_LOOPS    1000
#define DEFAULT_THREADS  4

int main(int argc, char** argv) {
    // 1. Determine parameters to use (Order: ./aho [threads] [loops] [patterns] [data])
    // argc[0] is the program name
    int num_threads           = (argc >= 2) ? atoi(argv[1]) : DEFAULT_THREADS;
    int loops                 = (argc >= 3) ? atoi(argv[2]) : DEFAULT_LOOPS;
    const char* patterns_path = (argc >= 4) ? argv[3] : DEFAULT_PATTERNS;
    const char* data_path     = (argc >= 5) ? argv[4] : DEFAULT_DATA;
    
    // Set the number of threads for OpenMP
    omp_set_num_threads(num_threads);

    printf("--- Execution Setup ---\n");
    printf("Threads to use : %d\n", num_threads);
    printf("Loops          : %d\n", loops);
    printf("Patterns file  : %s\n", patterns_path);
    printf("Data file      : %s\n", data_path);
    printf("-----------------------\n");

    // 2. Automaton preparation
    AC_Machine *nids = ac_create();
    
    printf("\n--- 1. Loading rules ---\n");
    // We pass the resolved patterns_path
    load_patterns(nids, patterns_path); 
    
    printf("Building the automaton...\n");
    ac_finalize(nids);
    
    printf("States: %d | Memory: %.2f MB\n", 
           nids->num_states, 
           (double)(nids->num_states * ALPHABET_SIZE * sizeof(int)) / (1024*1024));

    // 3. Loading data
    printf("\n--- 2. Loading data ---\n");
    long data_len;
    char* payload = load_file(data_path, &data_len);
    printf("Payload size: %.2f MB\n", (double)data_len / (1024*1024));

    // 4. Benchmark (Execution Engine)
    printf("\n--- 3. Starting Benchmark (OpenMP) ---\n");
    // Verify how many threads are actually running
    int actual_threads;
    #pragma omp parallel
    {
        #pragma omp single
        actual_threads = omp_get_num_threads();
    }
    printf("Threads active: %d | Total loops: %d\n", actual_threads, loops);

    long matches = 0;
    double start_time = omp_get_wtime();

    #pragma omp parallel for reduction(+:matches)
    for (int i = 0; i < loops; i++) {
        matches += ac_search_benchmark(nids, payload, data_len);
    }

    double end_time = omp_get_wtime();
    double time_total = end_time - start_time;

    // 5. Statistics
    unsigned long long total_bytes = (unsigned long long)data_len * loops;
    double throughput_mbps = ((double)total_bytes * 8) / (time_total * 1000000);

    printf("--------------------------------\n");
    printf("Time elapsed     : %.4f seconds\n", time_total);
    printf("Total matches    : %ld\n", matches);
    printf("Throughput       : %.2f Mbps\n", throughput_mbps);
    printf("--------------------------------\n");

    // 6. Cleanup
    free(payload);
    ac_free(nids);
    
    return 0;
}