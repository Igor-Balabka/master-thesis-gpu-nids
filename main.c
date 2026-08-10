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

volatile int stop_program = 0;
static struct ConsumerData my_consumers[RTE_MAX_LCORE];
static struct ProducerData my_producers[RTE_MAX_LCORE];

int main(int argc, char **argv) {
    memset(my_consumers, 0, sizeof(my_consumers));
    memset(my_producers, 0, sizeof(my_producers));

    // 1. DPDK EAL Initialization
    int ret = rte_eal_init(argc, argv);
    if (ret < 0) {
        rte_exit(EXIT_FAILURE, "Error during DPDK EAL initialization\n");
    }

    argc -= ret;
    argv += ret;

    // 2. Application Arguments Parsing
    const char *rules_file = NULL;
    int use_gpu = 0;
    int benchmark_in_memory = 0;
    int user_rx_queues = 1; // Default value: 1 queue
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

    if (!rules_file) {
        fprintf(stderr, "❌ Error: No rules file specified!\n");
        exit(1);
    }

    // Dynamic definition of batches per queue
    if (user_batches_per_q > 0) {
        g_batches_per_queue = user_batches_per_q;
    } else {
        g_batches_per_queue = 128; // Default: 128 batches per queue
    }

    // Global batch buffer size calculation
    int total_batches = g_batches_per_queue * user_rx_queues;
    if (total_batches < 512) total_batches = 512;

    unsigned int total_lcores = rte_lcore_count();
    printf("\n🚀 SELECTED MODE: %s %s (%u allocated core(s), %d RX Queue(s), %d Batches/Queue)\n", 
           use_gpu ? "GPU ACCELERATED" : "PURE CPU MULTI-WORKERS",
           benchmark_in_memory ? "[IN-MEMORY BENCHMARK]" : "[DPDK STREAMING]",
           total_lcores, user_rx_queues, g_batches_per_queue);

    // Aho-Corasick DFA Initialization
    AC_Automata *m = ac_create();
    load_patterns(m, rules_file);
    ac_finalize(m);

    if (use_gpu) {
        gpu_init_dfa(m);
    }

    // ── IN-MEMORY BENCHMARK (Maximum Raw Compute Throughput of the GPU) ──
    if (benchmark_in_memory && use_gpu) {
        printf("⚡ Loading trace into RAM for max GPU throughput evaluation...\n");

        uint32_t test_pkts = 1000000; // 1 Million packets
        size_t payload_bytes = (size_t)test_pkts * MAX_PAYLOAD_SIZE;

        char *h_data = (char *)malloc(payload_bytes);
        uint32_t *h_lens = (uint32_t *)malloc(test_pkts * sizeof(uint32_t));

        memset(h_data, 'A', payload_bytes);
        for (uint32_t i = 0; i < test_pkts; i++) {
            h_lens[i] = 1400;
        }

        printf("🔥 Launching raw GPU throughput measurement (1M Packets)...\n");

        struct timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC, &t0);

        unsigned long long matches = 0;
        uint32_t processed = 0;
        int stream_idx = 0;

        while (processed < test_pkts) {
            uint32_t batch_pkts = (test_pkts - processed > MAX_PKTS_PER_SLOT) ? MAX_PKTS_PER_SLOT : (test_pkts - processed);

            while (!gpu_is_stream_ready(stream_idx)) { rte_pause(); }
            matches += gpu_collect_stream_matches(stream_idx);

            gpu_process_batch_async_submit(
                h_data + ((size_t)processed * MAX_PAYLOAD_SIZE),
                h_lens + processed,
                batch_pkts,
                stream_idx
            );

            processed += batch_pkts;
            stream_idx = (stream_idx + 1) % NUM_STREAMS;
        }

        gpu_synchronize_all();
        for (int s = 0; s < NUM_STREAMS; s++) {
            matches += gpu_collect_stream_matches(s);
        }

        clock_gettime(CLOCK_MONOTONIC, &t1);

        double elapsed = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
        double total_bits = (double)test_pkts * 1400.0 * 8.0;
        double throughput_gbps = total_bits / (elapsed * 1e9);

        printf("\n==================================================\n");
        printf("📊 GPU MAX COMPUTE BENCHMARK (IN-MEMORY)\n");
        printf("==================================================\n");
        printf("Execution Time         : %.4f s\n",     elapsed);
        printf("Raw GPU Throughput     : %.2f Gbps 🚀🔥\n", throughput_gbps);
        printf("AC Matches             : %llu\n",        matches);
        printf("==================================================\n\n");

        free(h_data);
        free(h_lens);
        gpu_free_dfa();
        ac_free(m);
        return 0;
    }

    // ── ADAPTIVE STANDARD DPDK STREAMING PIPELINE ──
    struct rte_ring *packet_queue = rte_ring_create("SHARED_MPMC_RING", total_batches, rte_socket_id(), 0);
    struct PacketBatch *batch_list = (struct PacketBatch *)calloc(total_batches, sizeof(struct PacketBatch));
    struct rte_mempool *mbuf_pool = rte_pktmbuf_pool_create("MBUF_POOL", 16383, 256, 0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());

    uint16_t port_id = 0;
    struct rte_eth_dev_info dev_info;
    rte_eth_dev_info_get(port_id, &dev_info);

    uint16_t nb_rx_queues = (user_rx_queues > dev_info.max_rx_queues) ? dev_info.max_rx_queues : user_rx_queues;
    if (nb_rx_queues == 0) nb_rx_queues = 1;

    printf("[DPDK Config] Configuring Port %u with %u RX Queue(s)...\n", port_id, nb_rx_queues);

    struct rte_eth_conf port_conf = {0};
    rte_eth_dev_configure(port_id, nb_rx_queues, 0, &port_conf);

    for (uint16_t q = 0; q < nb_rx_queues; q++) {
        rte_eth_rx_queue_setup(port_id, q, 512, rte_eth_dev_socket_id(port_id), NULL, mbuf_pool);
    }

    rte_eth_dev_start(port_id);
    __atomic_store_n(&port_started, 1, __ATOMIC_RELEASE);

    unsigned int lcore_id;
    int worker_idx = 0;
    unsigned long long total_matches = 0;

    if (total_lcores > 1) {
        RTE_LCORE_FOREACH_WORKER(lcore_id) {
            if (use_gpu) {
                if (worker_idx < nb_rx_queues) {
                    uint16_t rx_q = worker_idx;
                    my_producers[lcore_id].port_id = port_id;
                    my_producers[lcore_id].queue_id = rx_q;
                    my_producers[lcore_id].queue = packet_queue;
                    my_producers[lcore_id].batch_list = batch_list;
                    my_producers[lcore_id].total_batches = total_batches;
                    
                    printf("[Launch] Core %u dedicated to DPDK capture (RX Queue %u/%u)\n", lcore_id, rx_q, nb_rx_queues);
                    rte_eal_remote_launch(packet_capture_worker, &my_producers[lcore_id], lcore_id);
                }
            } else {
                if (worker_idx == 0) {
                    my_producers[lcore_id].port_id = port_id;
                    my_producers[lcore_id].queue_id = 0;
                    my_producers[lcore_id].queue = packet_queue;
                    my_producers[lcore_id].batch_list = batch_list;
                    my_producers[lcore_id].total_batches = total_batches;
                    
                    printf("[Launch] Core %u dedicated to DPDK capture (RX Queue 0)\n", lcore_id);
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

        while (!all_queues_done(nb_rx_queues) || !rte_ring_empty(packet_queue)) {
            struct PacketBatch *cpu_batch = NULL;
            if (rte_ring_dequeue(packet_queue, (void **)&cpu_batch) < 0) {
                rte_pause();
                continue;
            }

            while (!gpu_is_stream_ready(stream_idx)) { rte_pause(); }

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
        if (total_lcores == 1) {
            // Mode séquentiel 1 seul cœur : Traitement synchrone sans bloquer sur le Ring
            int empty_loops = 0;
            while (1) {
                struct rte_mbuf *bufs[MAX_PKTS_PER_SLOT];
                uint16_t nb_rx = rte_eth_rx_burst(port_id, 0, bufs, MAX_PKTS_PER_SLOT);
                if (nb_rx == 0) { 
                    if (++empty_loops > 5000) break; 
                    rte_pause(); 
                    continue; 
                }
                empty_loops = 0;

                for (int i = 0; i < nb_rx; i++) {
                    char *raw = rte_pktmbuf_mtod(bufs[i], char *); 
                    uint32_t len = rte_pktmbuf_pkt_len(bufs[i]); 
                    uint32_t hdr_offset = sizeof(struct rte_ether_hdr);

                    // Filtrage IPv4 obligatoire pour s'aligner sur le parsing de dpdk.c
                    struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(raw + hdr_offset); 
                    if ((ip->version_ihl >> 4) == 4) {
                        hdr_offset += (ip->version_ihl & 0x0f) * 4;
                        if (ip->next_proto_id == IPPROTO_TCP) {
                            hdr_offset += ((((struct rte_tcp_hdr *)(raw + hdr_offset))->data_off & 0xf0) >> 4) * 4;
                        } else if (ip->next_proto_id == IPPROTO_UDP) {
                            hdr_offset += sizeof(struct rte_udp_hdr);
                        } else {
                            rte_pktmbuf_free(bufs[i]);
                            continue;
                        }

                        uint32_t payload_len = (len > hdr_offset) ? len - hdr_offset : 0; 
                        if (payload_len > MAX_PAYLOAD_SIZE) payload_len = MAX_PAYLOAD_SIZE;
                        if (payload_len > 0) {
                            total_matches += ac_search_benchmark(m, raw + hdr_offset, payload_len);
                        }
                    }
                    rte_pktmbuf_free(bufs[i]);
                }
            }
        } else {
            // Mode Multi-cœurs (2 cœurs et plus)
            unsigned int master_lcore = rte_get_main_lcore();

            // 1. Dépiler le ring pendant que la capture est active
            while (!all_queues_done(nb_rx_queues) || rte_ring_count(packet_queue) > 0) {
                struct PacketBatch *cpu_batch = NULL;
                if (rte_ring_dequeue(packet_queue, (void **)&cpu_batch) == 0) {
                    for (uint32_t i = 0; i < cpu_batch->num_pkts; i++) {
                        char *pkt_ptr = cpu_batch->packet_data + ((size_t)i * MAX_PAYLOAD_SIZE);
                        uint32_t len = cpu_batch->lengths[i];
                        if (len > 0) {
                            my_consumers[master_lcore].matches_counter += ac_search_benchmark(m, pkt_ptr, len);
                        }
                    }
                    __atomic_store_n(&cpu_batch->in_use, 0, __ATOMIC_RELEASE);
                } else {
                    rte_pause();
                }
            }

            // 2. Attendre 50ms pour s'assurer qu'aucun batch résiduel ne traîne
            rte_delay_ms(50);

            // 3. Vidage ultime du Ring
            struct PacketBatch *cpu_batch = NULL;
            while (rte_ring_dequeue(packet_queue, (void **)&cpu_batch) == 0) {
                for (uint32_t i = 0; i < cpu_batch->num_pkts; i++) {
                    char *pkt_ptr = cpu_batch->packet_data + ((size_t)i * MAX_PAYLOAD_SIZE);
                    uint32_t len = cpu_batch->lengths[i];
                    if (len > 0) {
                        my_consumers[master_lcore].matches_counter += ac_search_benchmark(m, pkt_ptr, len);
                    }
                }
                __atomic_store_n(&cpu_batch->in_use, 0, __ATOMIC_RELEASE);
            }

            // 4. Signal d'arrêt et synchronisation des workers
            __atomic_store_n(&stop_program, 1, __ATOMIC_RELEASE);
            rte_eal_mp_wait_lcore();

            // 5. Accumulation des matches de tous les consumers
            for (unsigned int i = 0; i < RTE_MAX_LCORE; i++) {
                total_matches += my_consumers[i].matches_counter;
            }
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);

    double elapsed = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    double throughput_gbps = (4900.0 * 1024.0 * 1024.0 * 8.0) / (elapsed * 1e9);

    printf("\n==================================================\n");
    printf("📊 AUTO-ADAPTIVE NIDS BENCHMARK (%s)\n", use_gpu ? "GPU MODE" : "PURE CPU MODE");
    printf("==================================================\n");
    printf("Allocated Cores        : %u\n",          total_lcores);
    printf("Active RX Queues       : %u\n",          nb_rx_queues);
    printf("Execution Time         : %.4f s\n",     elapsed);
    printf("Effective Throughput   : %.2f Gbps 🚀\n", throughput_gbps);
    printf("AC Matches             : %llu\n",        total_matches);
    printf("==================================================\n\n");

    rte_eth_dev_stop(port_id);
    free(batch_list);
    ac_free(m);
    return 0;
}