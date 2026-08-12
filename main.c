#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_mempool.h>
#include <rte_ring.h>
#include <rte_lcore.h>
#include <rte_ether.h>
#include <rte_ip.h>
#include <rte_tcp.h>
#include <rte_udp.h>

#include "config.h"
#include "ac.h"
#include "dpdk.h"
#include "gpu_engine.h"

// Global flags and thread tracking arrays
volatile int stop_program = 0;
static struct ConsumerData my_consumers[RTE_MAX_LCORE];
static struct ProducerData my_producers[RTE_MAX_LCORE];

// Global variable to track processed bytes across CPU workers
unsigned long long global_bytes_processed = 0;

int main(int argc, char **argv) {
    // Clear consumer and producer structs
    memset(my_consumers, 0, sizeof(my_consumers));
    memset(my_producers, 0, sizeof(my_producers));

    // 1. Initialize DPDK Environment Abstraction Layer (EAL)
    int ret = rte_eal_init(argc, argv);
    if (ret < 0) {
        rte_exit(EXIT_FAILURE, "Error during DPDK EAL initialization\n");
    }

    argc -= ret;
    argv += ret;

    // 2. Parse command-line arguments
    const char *rules_file = NULL;
    int use_gpu = 0;
    int benchmark_in_memory = 0;
    int user_rx_queues = 1; 
    int user_batches_per_q = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
            if (strcmp(argv[i+1], "gpu") == 0) use_gpu = 1;
            i++;
            continue;
        }
        if (strcmp(argv[i], "--rx-queues") == 0 || strcmp(argv[i], "-q") == 0) {
            if (i + 1 < argc) {
                user_rx_queues = atoi(argv[i+1]);
                if (user_rx_queues < 1) user_rx_queues = 1;
                i++;
            }
            continue;
        }
        if (strcmp(argv[i], "--batches-per-queue") == 0 || strcmp(argv[i], "-b") == 0) {
            if (i + 1 < argc) {
                user_batches_per_q = atoi(argv[i+1]);
                if (user_batches_per_q < 1) user_batches_per_q = 1;
                i++;
            }
            continue;
        }
        if (strcmp(argv[i], "--in-memory") == 0 || strcmp(argv[i], "-m") == 0) {
            benchmark_in_memory = 1;
            continue;
        }
        if (argv[i][0] != '-') {
            rules_file = argv[i];
        }
    }

    // Check if a rules file was provided
    if (!rules_file) {
        fprintf(stderr, "Error: No rules file specified!\n");
        exit(1);
    }

    // Set batch sizes dynamically
    if (user_batches_per_q > 0) {
        g_batches_per_queue = user_batches_per_q;
    } else {
        g_batches_per_queue = 256; 
    }

    int total_batches = g_batches_per_queue * user_rx_queues;
    if (total_batches < 512) total_batches = 512;

    unsigned int total_lcores = rte_lcore_count();
    printf("\nSELECTED MODE: %s %s (%u allocated core(s), %d RX Queue(s), %d Batches/Queue)\n", 
           use_gpu ? "GPU ACCELERATED" : "PURE CPU MULTI-WORKERS",
           benchmark_in_memory ? "[IN-MEMORY BENCHMARK]" : "[DPDK STREAMING]",
           total_lcores, user_rx_queues, g_batches_per_queue);

    // Create and build the Aho-Corasick automaton
    AC_Automata *m = ac_create();
    load_patterns(m, rules_file);
    ac_finalize(m);

    // Initialize GPU DFA if GPU mode is active
    if (use_gpu) {
        gpu_init_dfa(m);
    }

    // ── IN-MEMORY BENCHMARK MODE ──
    if (benchmark_in_memory && use_gpu) {
        int num_files = user_rx_queues;
        if (num_files < 1) num_files = 1;
        if (num_files > 4) num_files = 4;

        MbufPool *pools[4] = {NULL};
        unsigned int total_combined_packets = 0;

        printf("Loading %d trace file(s) into RAM...\n", num_files);

        for (int f = 0; f < num_files; f++) {
            char filepath[256];
            if (num_files == 1) {
                snprintf(filepath, sizeof(filepath), "Pcap/MixFile.pcap");
            } else {
                snprintf(filepath, sizeof(filepath), "Pcap/MixFile_%dq_%d.pcap", num_files, f + 1);
            }

            printf("  -> Loading %s ...\n", filepath);
            pools[f] = load_pcap_to_mbuf_pool(filepath);
            if (!pools[f]) {
                fprintf(stderr, "Error loading trace file: %s\n", filepath);
                for (int i = 0; i < f; i++) free_mbuf_pool(pools[i]);
                exit(1);
            }
            total_combined_packets += pools[f]->packet_count;
        }

        struct timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC, &t0);

        unsigned long long matches = 0;
        int stream_idx = 0;

        // Process packets in memory using GPU streams
        for (int f = 0; f < num_files; f++) {
            MbufPool *pool = pools[f];
            size_t processed = 0;

            while (processed < pool->packet_count) {
                uint32_t batch_pkts = (pool->packet_count - processed > MAX_PKTS_PER_SLOT) ? MAX_PKTS_PER_SLOT : (pool->packet_count - processed);

                char *h_data = (char *)malloc((size_t)batch_pkts * MAX_PAYLOAD_SIZE);
                uint32_t *h_lens = (uint32_t *)malloc((size_t)batch_pkts * sizeof(uint32_t));
                memset(h_data, 0, (size_t)batch_pkts * MAX_PAYLOAD_SIZE);

                for (uint32_t i = 0; i < batch_pkts; i++) {
                    h_lens[i] = pool->mbuf_array[processed + i].data_len;
                    memcpy(h_data + (i * MAX_PAYLOAD_SIZE), pool->mbuf_array[processed + i].buf_addr, h_lens[i]);
                }

                while (!gpu_is_stream_ready(stream_idx)) { rte_pause(); }
                matches += gpu_collect_stream_matches(stream_idx);

                gpu_process_batch_async_submit(h_data, h_lens, batch_pkts, stream_idx);

                free(h_data);
                free(h_lens);
                processed += batch_pkts;
                stream_idx = (stream_idx + 1) % NUM_STREAMS;
            }
        }

        gpu_synchronize_all();
        for (int s = 0; s < NUM_STREAMS; s++) {
            matches += gpu_collect_stream_matches(s);
        }

        clock_gettime(CLOCK_MONOTONIC, &t1);

        double elapsed = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
        
        uint64_t total_combined_bytes = 0;
        for (int f = 0; f < num_files; f++) {
            total_combined_bytes += pools[f]->total_bytes;
        }

        double total_bits = (double)total_combined_bytes * 8.0;
        double throughput_gbps = (elapsed > 0.0) ? total_bits / (elapsed * 1e9) : 0.0;

        printf("\n==================================================\n");
        printf("GPU MULTI-FILE IN-MEMORY BENCHMARK (%d Queues)\n", num_files);
        printf("==================================================\n");
        printf("Execution Time         : %.4f s\n",     elapsed);
        printf("Real Trace Throughput  : %.2f Gbps\n",    throughput_gbps);
        printf("AC Matches             : %llu\n",        matches);
        printf("==================================================\n\n");

        printf("METRICS_DATA:256,%u,%.2f,%d,%llu,%llu,%.4f\n", 
               MAX_PKTS_PER_SLOT, throughput_gbps, num_files, matches, matches, elapsed);

        for (int f = 0; f < num_files; f++) {
            free_mbuf_pool(pools[f]);
        }
        gpu_free_dfa();
        ac_free(m);
        return 0;
    }

    // ── DPDK STREAMING PIPELINE MODE ──
    struct rte_ring *packet_queue = rte_ring_create("SHARED_MPMC_RING", total_batches, rte_socket_id(), 0);
    struct PacketBatch *batch_list = (struct PacketBatch *)calloc(total_batches, sizeof(struct PacketBatch));
    struct rte_mempool *mbuf_pool = rte_pktmbuf_pool_create("MBUF_POOL", 16383, 256, 0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());

    uint16_t nb_available_ports = rte_eth_dev_count_avail();
    uint16_t nb_ports_to_use = (user_rx_queues < nb_available_ports) ? user_rx_queues : nb_available_ports;
    if (nb_ports_to_use == 0) nb_ports_to_use = 1;

    printf("[DPDK Config] Configuring %u active port(s) for multi-stream capture...\n", nb_ports_to_use);

    for (uint16_t p = 0; p < nb_ports_to_use; p++) {
        struct rte_eth_conf port_conf = {0};
        rte_eth_dev_configure(p, 1, 0, &port_conf);
        rte_eth_rx_queue_setup(p, 0, 512, rte_eth_dev_socket_id(p), NULL, mbuf_pool);
        rte_eth_dev_start(p);
    }

    rte_delay_ms(100);
    __atomic_store_n(&port_started, 1, __ATOMIC_RELEASE);

    unsigned int lcore_id;
    int worker_idx = 0;
    unsigned long long total_matches = 0;
    unsigned long long total_bytes_processed = 0;

    // Launch worker threads across available CPU cores
    if (total_lcores > 1) {
        RTE_LCORE_FOREACH_WORKER(lcore_id) {
            if (use_gpu) {
                if (worker_idx < nb_ports_to_use) {
                    uint16_t target_port = worker_idx;
                    my_producers[lcore_id].port_id = target_port;
                    my_producers[lcore_id].queue_id = 0;
                    my_producers[lcore_id].queue = packet_queue;
                    my_producers[lcore_id].batch_list = batch_list;
                    my_producers[lcore_id].total_batches = total_batches;
                    
                    printf("[Launch] Core %u dedicated to capture Port %u\n", lcore_id, target_port);
                    rte_eal_remote_launch(packet_capture_worker, &my_producers[lcore_id], lcore_id);
                }
            } else {
                if (worker_idx == 0) {
                    my_producers[lcore_id].port_id = 0;
                    my_producers[lcore_id].queue_id = 0;
                    my_producers[lcore_id].queue = packet_queue;
                    my_producers[lcore_id].batch_list = batch_list;
                    my_producers[lcore_id].total_batches = total_batches;
                    
                    printf("[Launch] Core %u dedicated to DPDK capture (Port 0)\n", lcore_id);
                    rte_eal_remote_launch(packet_capture_worker, &my_producers[lcore_id], lcore_id);
                } else {
                    my_consumers[lcore_id].queue = packet_queue;
                    my_consumers[lcore_id].ac_tree = m;
                    my_consumers[lcore_id].matches_counter = 0;
                    
                    printf("[Launch] Core %u dedicated to CPU analysis worker\n", lcore_id);
                    rte_eal_remote_launch(packet_analysis_worker, &my_consumers[lcore_id], lcore_id);
                }
            }
            worker_idx++;
        }
    }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    if (use_gpu) {
        int stream_idx = 0;
        int stream_active[NUM_STREAMS] = {0};

        while (!all_queues_done(nb_ports_to_use) || !rte_ring_empty(packet_queue)) {
            struct PacketBatch *cpu_batch = NULL;
            if (rte_ring_dequeue(packet_queue, (void **)&cpu_batch) < 0) {
                rte_pause();
                continue;
            }

            for (uint32_t b_i = 0; b_i < cpu_batch->num_pkts; b_i++) {
                total_bytes_processed += cpu_batch->lengths[b_i];
            }

            int max_tries = 0;
            while (!gpu_is_stream_ready(stream_idx) && max_tries < 100) {
                stream_idx = (stream_idx + 1) % NUM_STREAMS;
                max_tries++;
            }

            if (stream_active[stream_idx]) {
                total_matches += gpu_collect_stream_matches(stream_idx);
            }

            gpu_process_batch_async_submit(
                cpu_batch->packet_data, 
                cpu_batch->lengths, 
                cpu_batch->num_pkts, 
                stream_idx
            );

            stream_active[stream_idx] = 1;
            __atomic_store_n(&cpu_batch->in_use, 0, __ATOMIC_RELEASE);

            stream_idx = (stream_idx + 1) % NUM_STREAMS;
        }

        gpu_synchronize_all();
        for (int s = 0; s < NUM_STREAMS; s++) {
            if (stream_active[s]) {
                total_matches += gpu_collect_stream_matches(s);
            }
        }

        gpu_free_dfa();
    } else {
        // CPU mode: wait until all queues are done processing
        while (!all_queues_done(nb_ports_to_use) || rte_ring_count(packet_queue) > 0) {
            rte_delay_ms(10);
        }

        // Signal workers to stop and wait for them to finish
        __atomic_store_n(&stop_program, 1, __ATOMIC_RELEASE);
        rte_eal_mp_wait_lcore();
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);

    double elapsed = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    
    // Aggregate total matches from all consumer cores
    for (unsigned int i = 0; i < RTE_MAX_LCORE; i++) {
        total_matches += my_consumers[i].matches_counter;
    }

    // Get the exact size of the PCAP trace file to compute throughput reliably
    FILE *f = fopen("/dev/shm/MixFile.pcap", "rb");
    if (f) {
        fseek(f, 0, SEEK_END);
        total_bytes_processed = ftell(f);
        fclose(f);
    } else {
        f = fopen("Pcap/MixFile.pcap", "rb");
        if (f) {
            fseek(f, 0, SEEK_END);
            total_bytes_processed = ftell(f);
            fclose(f);
        }
    }

    double throughput_gbps = (elapsed > 0.0) ? ((double)total_bytes_processed * 8.0) / (elapsed * 1e9) : 0.0;

    // Print benchmark summary
    printf("\n==================================================\n");
    printf("AUTO-ADAPTIVE NIDS BENCHMARK (%s)\n", use_gpu ? "GPU MODE" : "CPU MODE");
    printf("==================================================\n");
    printf("Allocated Cores        : %u\n",          total_lcores);
    printf("Active RX Queues       : %u\n",          nb_ports_to_use);
    printf("Execution Time         : %.4f s\n",     elapsed);
    printf("Effective Throughput   : %.2f Gbps\n",    throughput_gbps);
    printf("AC Matches             : %llu\n",        total_matches);
    printf("==================================================\n\n");

    printf("METRICS_DATA:256,%u,%.2f,1,%llu,%llu,%.4f\n", 
           MAX_PKTS_PER_SLOT, throughput_gbps, total_matches, total_matches, elapsed);

    // Clean up ports and resources
    for (uint16_t p = 0; p < nb_ports_to_use; p++) {
        rte_eth_dev_stop(p);
    }
    free(batch_list);
    ac_free(m);
    return 0;
}