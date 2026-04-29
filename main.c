#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pcap.h>
#include <omp.h>
#include "payload.h"
#include "ac.h"
#include "Kernel/ac_classic.h"
#include "Kernel/ac_double_buffering.h"

// Prototype
void load_patterns(AC_Machine *m, const char *filename);

int main(int argc, char const *argv[]) {
    // 1. Vérification stricte des arguments pour le script .sh
    if (argc < 6) {
        printf("Usage: %s <mode> <param> <loops> <rules_path> <pcap_path> [block_size]\n", argv[0]);
        return EXIT_FAILURE;
    }

    // Mapping des arguments envoyés par le script
    const char *mode       = argv[1]; // "cpu", "gpu" ou "gpu_async"
    int threads_or_param   = atoi(argv[2]);
    int loops              = atoi(argv[3]);
    const char *rules_file = argv[4]; 
    const char *pcap_file  = argv[5]; 
    int block_size         = (argc > 6) ? atoi(argv[6]) : 256;
    int batch_size = (argc > 7) ? atoi(argv[7]) : 65536;
    int n_slots    = (argc > 8) ? atoi(argv[8]) : 8;

    // 2. Setup de l'automate Aho-Corasick
    AC_Machine *m = ac_create();
    load_patterns(m, rules_file); 
    ac_finalize(m);

    // 3. Chargement du fichier PCAP (Utilise pcap_file, l'argument 5 !)
    PcapDataStore *pcapData = load_pcap_to_memory(pcap_file); 
    if (!pcapData) {
        ac_free(m);
        return EXIT_FAILURE;
    }
    size_t last_idx = pcapData->packet_count - 1;
    unsigned long total_data_size = pcapData->offsets[last_idx] + pcapData->sizes[last_idx];

    long total_matches = 0;
    double exec_time = 0.0;

    // 4. Logique de décision pour le Benchmark
    if (strcmp(mode, "gpu") == 0) {
        // Mode GPU Synchronous
        exec_time = run_classic_packet_benchmark(
            m, (const char*)pcapData->raw_data, (unsigned long*)pcapData->offsets, 
            (int*)pcapData->sizes, pcapData->packet_count, loops, &total_matches
        );
    } 
    else if (strcmp(mode, "gpu_async") == 0) {
    exec_time = run_buffering_packet_benchmark(
        m, (const char*)pcapData->raw_data, (unsigned long*)pcapData->offsets, 
        (int*)pcapData->sizes, pcapData->packet_count, loops, &total_matches, 
        block_size, batch_size, n_slots // Ajout de n_slots ici
    );
}
    else if (strcmp(mode, "cpu") == 0) {
        // Mode CPU Multi-thread (OpenMP)
        omp_set_num_threads(threads_or_param);
        double start_cpu = omp_get_wtime();
        for(int l = 0; l < loops; l++) {
            total_matches = 0;
            #pragma omp parallel for reduction(+:total_matches)
            for (unsigned int i = 0; i < pcapData->packet_count; i++) {
                total_matches += ac_search_benchmark(m, 
                    (const char*)(pcapData->raw_data + pcapData->offsets[i]), 
                    pcapData->sizes[i]);
            }
        }
        exec_time = (omp_get_wtime() - start_cpu) / loops;
    }

    // 5. SORTIE FORMATÉE (Crucial pour le script Bash)
    double total_bits = (double)total_data_size * 8.0;
    double throughput = (total_bits) / (exec_time * 1000000000.0);
    printf("--- Statistics ---\n");
    printf("Total Matches : %ld\n", total_matches);
    printf("Time Elapsed : %.6f s\n", exec_time);
    printf("Throughput : %.2f Gbps\n", throughput);

    // 6. Cleanup
    free_pcap_store(pcapData);
    ac_free(m);

    return 0;
}

// Implémentation de load_patterns
void load_patterns(AC_Machine *m, const char *filename) {
    FILE *file = fopen(filename, "r");
    if (!file) { 
        fprintf(stderr, "❌ Error: Could not open rules file %s\n", filename); 
        exit(1); 
    }
    char line[1024];
    int id = 1;
    while (fgets(line, sizeof(line), file)) {
        line[strcspn(line, "\r\n")] = 0;
        if (strlen(line) > 0) ac_add_pattern(m, line, id++);
    }
    fclose(file);
    printf("[Setup] %d patterns loaded from %s\n", id - 1, filename);
}