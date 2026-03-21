#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cuda_runtime.h>
#include <pcap.h>
#include <omp.h>

#include "ac.h"
#include "payload.h"

// --- Global Defaults ---
#define DEFAULT_MODE       "CPU"
#define DEFAULT_THREADS    4
#define DEFAULT_BLOCK_SIZE 256
#define MAX_BATCH_PKTS     1000000
#define BATCH_SIZE_500MB   (1000ULL * 1024 * 1024)

// --- Function Prototypes ---
void load_patterns_from_file(AC_Machine *m, const char *filename);
long run_cpu_benchmark(AC_Machine *m, char *payload, PacketData *meta, int num_pkts, int threads, double *pure_time);
long run_gpu_benchmark(AC_Machine *m, char *h_payload, PacketData *h_meta, int num_pkts, int blockSize, int gridSize, double *pure_time);

// --- 1. CPU Logic (With Internal Timer) ---
long run_cpu_benchmark(AC_Machine *m, char *payload, PacketData *meta, int num_pkts, int threads, double *pure_time) {
    long matches = 0;
    omp_set_num_threads(threads);

    // --- Start Internal Timer ---
    double start = omp_get_wtime();

    #pragma omp parallel for reduction(+:matches)
    for (int i = 0; i < num_pkts; i++) {
        char *pkt_ptr = payload + meta[i].offset;
        int pkt_len = meta[i].length;
        matches += ac_search_benchmark(m, pkt_ptr, pkt_len);
    }

    // --- End Internal Timer ---
    *pure_time += (omp_get_wtime() - start);
    
    return matches;
}

// --- 2. GPU Logic (Template with Internal Timer) ---
long run_gpu_benchmark(AC_Machine *m, char *h_payload, PacketData *h_meta, int num_pkts, int blockSize, int gridSize, double *pure_time) {
    long matches = 0;
    
    // Arrays needed by your run_classic_packet_benchmark function
    // We use static to allocate only once and reuse the memory across batches
    static long *batch_offsets = NULL;
    static int *batch_lengths = NULL;
    static int current_capacity = 0;

    // Reallocate only if the current batch is larger than our previous maximum
    if (num_pkts > current_capacity) {
        if (batch_offsets) free(batch_offsets);
        if (batch_lengths) free(batch_lengths);
        batch_offsets = (long*)malloc(num_pkts * sizeof(long));
        batch_lengths = (int*)malloc(num_pkts * sizeof(int));
        current_capacity = num_pkts;
    }

    // Prepare the simplified arrays from the h_meta struct
    #pragma omp parallel for // Parallelize the copy to be even faster
    for (int i = 0; i < num_pkts; i++) {
        batch_offsets[i] = h_meta[i].offset;
        batch_lengths[i] = h_meta[i].length;
    }

    // --- CALL YOUR CUDA KERNEL WRAPPER ---
    // Your run_classic_packet_benchmark already contains internal timing with cudaEvents
    // It returns the execution time in seconds (double)
    double start = omp_get_wtime();
    double kernel_time = run_classic_packet_benchmark(
        m, 
        h_payload, 
        batch_offsets, 
        batch_lengths, 
        num_pkts, 
        1,       // loops = 1
        &matches // will store the total matches found in this batch
    );

    // Update the pure matching time shared variable
    *pure_time += (omp_get_wtime() - start);
    
    return matches;
}

// --- 3. Rules Loader ---
void load_patterns_from_file(AC_Machine *m, const char *filename) {
    FILE *file = fopen(filename, "r");
    if (!file) {
        fprintf(stderr, "Error: Could not open %s\n", filename);
        exit(1);
    }
    char line[1024];
    int id = 1;
    while (fgets(line, sizeof(line), file)) {
        line[strcspn(line, "\r\n")] = 0;
        if (strlen(line) > 0) ac_add_pattern(m, line, id++);
    }
    fclose(file);
    printf("[Setup] %d patterns loaded\n", id - 1);
}

// --- 4. Main Controller ---
int main(int argc, char** argv) {
    const char* mode = (argc >= 2) ? argv[1] : DEFAULT_MODE;
    int threads_or_block = (argc >= 3) ? atoi(argv[2]) : 
                           (strcasecmp(mode, "GPU") == 0 ? DEFAULT_BLOCK_SIZE : DEFAULT_THREADS);
    int gridSize = (argc >= 4) ? atoi(argv[3]) : 0;

    printf("================ Configuration ================\n");
    printf("Execution Mode   : %s\n", mode);
    printf("Target Hardware  : %d %s\n", threads_or_block, (strcasecmp(mode, "GPU") == 0 ? "Threads/Block" : "Threads"));
    printf("===============================================\n");

    AC_Machine *m = ac_create();
    load_patterns_from_file(m, "Rules/patterns.txt");
    ac_finalize(m);

    char errbuf[PCAP_ERRBUF_SIZE];
    pcap_t *handle = pcap_open_offline("Data/MixFile.pcap", errbuf);
    if (!handle) return 1;

    char *payload; 
    PacketData *meta;
    cudaHostAlloc((void**)&meta, MAX_BATCH_PKTS * sizeof(PacketData), cudaHostAllocDefault);
    cudaHostAlloc((void**)&payload, BATCH_SIZE_500MB, cudaHostAllocDefault);

    long total_matches = 0;
    unsigned long long total_bytes = 0;
    int num_pkts;
    
    // Timers
    double global_start = omp_get_wtime();
    double pure_matching_time = 0.0;

    while ((num_pkts = packetMemoryManager(handle, payload, meta, MAX_BATCH_PKTS, BATCH_SIZE_500MB)) > 0) {
        long batch_matches = 0;

        for(int i = 0; i < num_pkts; i++) total_bytes += meta[i].length;

        if (strcasecmp(mode, "GPU") == 0) {
            batch_matches = run_gpu_benchmark(m, payload, meta, num_pkts, threads_or_block, gridSize, &pure_matching_time);
        } else {
            batch_matches = run_cpu_benchmark(m, payload, meta, num_pkts, threads_or_block, &pure_matching_time);
        }

        total_matches += batch_matches;
    }

    double global_duration = omp_get_wtime() - global_start;

    // --- STATS CALCULATION ---
    double total_gb = (double)total_bytes / (1e9); // Using decimal GB for throughput
    double global_throughput = (total_gb * 8.0) / global_duration;
    double matching_throughput = (total_gb * 8.0) / pure_matching_time;

    printf("\n================ FINAL STATISTICS ================\n");
    printf("Total Matches      : %ld\n", total_matches);
    printf("Total Data         : %.3f GB\n", total_gb);
    printf("--------------------------------------------------\n");
    printf("Global Time        : %.4f s (Disk + Load + Scan)\n", global_duration);
    printf("Global Throughput  : %.2f Gbps\n", global_throughput);
    printf("--------------------------------------------------\n");
    printf("Pattern Match Time : %.4f s (Compute Only)\n", pure_matching_time);
    printf("Pattern Match Speed: %.2f Gbps\n", matching_throughput);
    printf("==================================================\n");

    pcap_close(handle);
    ac_free(m);
    cudaFreeHost(payload); 
    cudaFreeHost(meta);
    return 0;
}