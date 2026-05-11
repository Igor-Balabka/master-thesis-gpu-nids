#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pcap.h>
#include <omp.h>
#include "payload.h"
#include "ac.h"
#include "Kernel/ac_classic.h"
#include "Kernel/ac_asychrone.h"
#include "Kernel/cuda_utils.h"

/**
 * Reads the rules file and populates the Aho-Corasick tree.
 * Each line in the file is treated as a new pattern/signature.
 */
void load_patterns(AC_Automata *m, const char *filename)
{
    FILE *file = fopen(filename, "r");
    if (!file)
    {
        fprintf(stderr, "❌ Error: Could not open rules file %s\n", filename);
        exit(1);
    }
    char line[1024];
    int id = 1;
    while (fgets(line, sizeof(line), file))
    {
        line[strcspn(line, "\r\n")] = 0;
        if (strlen(line) > 0)
            ac_add_pattern(m, line, id++);
    }
    fclose(file);
    printf("[Setup] %d patterns loaded from %s\n", id - 1, filename);
}

int main(int argc, char const *argv[])
{

    // 1. Basic argument parsing
    if (argc < 2)
    {
        printf("Usage: %s <mode> [params...]\n", argv[0]);
        return EXIT_FAILURE;
    }

    const char *mode = argv[1];

    // Special mode: just print GPU hardware info and exit
    if (strcmp(mode, "info") == 0)
    {
        print_gpu_specs();
        return EXIT_SUCCESS;
    }

    // Standard benchmark requires at least 6 arguments
    if (argc < 6)
    {
        printf("Usage: %s <mode> <param> <loops> <rules_path> <pcap_path> [block_size]\n", argv[0]);
        return EXIT_FAILURE;
    }

    int threads_or_param = atoi(argv[2]);
    int loops = atoi(argv[3]);
    const char *rules_file = argv[4];
    const char *pcap_file = argv[5];
    int block_size = (argc > 6) ? atoi(argv[6]) : 256;
    int batch_size = (argc > 7) ? atoi(argv[7]) : 65536;
    int n_slots = (argc > 8) ? atoi(argv[8]) : 8;

    // 2. Setup the Aho-Corasick Automaton
    // We create the tree, load patterns, and finalize it into a DFA
    AC_Automata *m = ac_create();
    load_patterns(m, rules_file);
    ac_finalize(m);

    // 3. Load PCAP file into Memory
    // Using the MbufPool system (similar to DPDK) to store packet data in pinned memory
    MbufPool *pool = load_pcap_to_mbuf_pool(pcap_file);
    if (pool == NULL)
    {
        ac_free(m);
        return EXIT_FAILURE;
    }

    unsigned long total_data_size = pool->total_bytes;

    long total_matches = 0;
    double exec_time = 0.0;

    printf("--- Statistics ---\n");

    // 4. Execution Engine Selection
    if (strcmp(mode, "gpu") == 0)
    {
        // Classic GPU Mode: Synchronous copy and execution        exec_time = run_classic_packet_benchmark(m, pool, loops, &total_matches);
        printf("block size : %d \n", block_size);
        printf("batch size : %d \n", batch_size);
        printf("number of buffer : %d \n", n_slots);
    }
    else if (strcmp(mode, "gpu_async") == 0)
    {
        // High Performance Mode: Asynchronous streams with multi-buffering
        exec_time = run_mbuf_benchmark(
            m, pool, loops, &total_matches,
            block_size, batch_size, n_slots);
        cudaDeviceSynchronize();
    }
    else if (strcmp(mode, "cpu") == 0)
    {
        // Multithreaded CPU Mode: Using OpenMP for comparison
        omp_set_num_threads(threads_or_param);
        double start_cpu = omp_get_wtime();
        for (int l = 0; l < loops; l++)
        {
            total_matches = 0;
            #pragma omp parallel for reduction(+ : total_matches)
            for (unsigned int i = 0; i < pool->packet_count; i++)
            {
                total_matches += ac_search_benchmark(m,
                                                     (const char *)pool->mbuf_array[i].buf_addr,
                                                     pool->mbuf_array[i].data_len);
            }
        }
        exec_time = (omp_get_wtime() - start_cpu) / loops;
        printf("number of threads : %d \n", threads_or_param);
    }

    // 5. Performance Metrics Calculation
    double total_bits = (double)total_data_size * 8.0;
    // Throughput in Gbps = (Total Bits) / (Time in seconds * 10^9)
    double throughput = (total_bits) / (exec_time * 1000000000.0);

    printf("Total Matches : %ld\n", total_matches);
    printf("Time Elapsed : %.6f s\n", exec_time);
    printf("Throughput : %.2f Gbps\n", throughput);


    // 6. Final Cleanup
    free_mbuf_pool(pool);
    ac_free(m);

    return 0;
}