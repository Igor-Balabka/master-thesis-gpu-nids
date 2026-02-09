#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <omp.h> // <--- INDISPENSABLE POUR LE MULTI-THREAD
#include "ac.h" 

// --- File Utilities ---

char* load_file(const char* filename, long* length) {
    FILE* f = fopen(filename, "rb");
    if (!f) { perror("Error reading data file"); exit(1); }
    
    fseek(f, 0, SEEK_END);
    *length = ftell(f);
    fseek(f, 0, SEEK_SET);
    
    char* buffer = (char*)malloc(*length + 1);
    fread(buffer, 1, *length, f);
    buffer[*length] = '\0';
    fclose(f);
    return buffer;
}

void load_patterns(AC_Machine* ac, const char* filename) {
    FILE* f = fopen(filename, "r");
    if (!f) { perror("Error reading patterns file"); exit(1); }
    
    char line[1024];
    int id = 1;
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\n")] = 0;
        if (strlen(line) > 0) {
            ac_add_pattern(ac, line, id++);
        }
    }
    fclose(f);
    printf("Patterns loaded: %d\n", id - 1);
}

// --- Main ---

int main(int argc, char** argv) {
    if (argc != 3) {
        printf("Usage: %s <patterns_file.txt> <data_to_scan.txt/bin>\n", argv[0]);
        return 1;
    }

    // 1. Initialisation
    AC_Machine *nids = ac_create();
    
    printf("--- 1. Loading rules ---\n");
    load_patterns(nids, argv[1]);
    
    printf("Building the automaton...\n");
    ac_finalize(nids);
    printf("States: %d | Table memory: %.2f MB\n", 
           nids->num_states, 
           (double)(nids->num_states * ALPHABET_SIZE * sizeof(int)) / (1024*1024));

    printf("\n--- 2. Loading data ---\n");
    long data_len;
    char* payload = load_file(argv[2], &data_len);
    printf("Payload loaded: %.2f MB\n", (double)data_len / (1024*1024));


    int max_threads = omp_get_max_threads();
    printf("\n--- 3. Starting Benchmark (OpenMP) ---\n");
    printf("Threads detected : %d\n", max_threads);


    int loops = 5000; 
    long matches = 0;
    

    double start_time = omp_get_wtime();


    #pragma omp parallel for reduction(+:matches)
    for (int i = 0; i < loops; i++)
    {
        matches += ac_search_benchmark(nids, payload, data_len);
    }

    double end_time = omp_get_wtime();
    double time_elapsed = end_time - start_time;


    unsigned long long total_bytes = (unsigned long long)data_len * loops;
    double throughput_mbps = ((double)total_bytes * 8) / (time_elapsed * 1000000); 
    
    printf("Scan finished!\n");
    printf("--------------------------------\n");
    printf("Threads used     : %d\n", max_threads);
    printf("Virtual Data Size: %.2f GB\n", (double)total_bytes / (1024*1024*1024));
    printf("Time elapsed     : %.4f seconds\n", time_elapsed);
    printf("Alerts found     : %ld\n", matches);
    printf("Throughput       : %.2f Mbps\n", throughput_mbps);
    printf("--------------------------------\n");

    free(payload);
    ac_free(nids);
    
    return 0;
}