#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_ring.h>
#include <rte_lcore.h>
#include <rte_ether.h>
#include <rte_ip.h>
#include <rte_tcp.h>
#include <rte_udp.h>

#include "dpdk.h"

// Global flags and counters for threads synchronization
volatile int port_started = 0;
volatile int queue_done[RTE_MAX_LCORE] = {0};
int g_batches_per_queue = 0; // Defined dynamically from main.c
static volatile uint32_t local_queue_counter[RTE_MAX_LCORE] = {0};

// Check if all RX queues have finished processing their packets
int all_queues_done(uint16_t nb_queues) {
    for (uint16_t q = 0; q < nb_queues; q++) {
        if (!__atomic_load_n(&queue_done[q], __ATOMIC_ACQUIRE)) {
            return 0;
        }
    }
    return 1;
}

// Producer thread: captures packets from network ports using DPDK and puts them into a ring buffer
int packet_capture_worker(void *arg) {
    struct ProducerData *args = (struct ProducerData *)arg;
    uint16_t port_id = args->port_id;
    uint16_t queue_id = args->queue_id;
    struct rte_ring *ring = args->queue;
    struct PacketBatch *batch_list = args->batch_list;
    int total_batches = args->total_batches;

    // Wait safely until the Ethernet port is fully started
    while (!__atomic_load_n(&port_started, __ATOMIC_ACQUIRE)) {
        if (__atomic_load_n(&stop_program, __ATOMIC_ACQUIRE)) return 0;
        rte_pause();
    }

    int b_per_q = g_batches_per_queue;
    if (b_per_q <= 0) b_per_q = total_batches / 4;
    if (b_per_q < 1) b_per_q = 1;

    int batch_start = (queue_id * b_per_q) % total_batches;
    struct rte_mbuf *pkts[MAX_PKTS_PER_SLOT];
    int empty_reads = 0;

    while (!__atomic_load_n(&stop_program, __ATOMIC_ACQUIRE)) {
        // Safety check: stop receiving if program requested exit
        if (__atomic_load_n(&stop_program, __ATOMIC_ACQUIRE)) break;

        // Burst receive packets from the network device
        uint16_t nb_rx = rte_eth_rx_burst(port_id, queue_id, pkts, MAX_PKTS_PER_SLOT);
        
        // If no packets arrive, count empty reads to avoid infinite idle loops
        if (nb_rx == 0) {
            empty_reads++;
            if (empty_reads > 50000) {
                __atomic_store_n(&queue_done[queue_id], 1, __ATOMIC_RELEASE);
                break; // Exit cleanly when trace/stream ends
            }
            rte_pause();
            continue;
        }

        empty_reads = 0;

        uint32_t ticket = __atomic_fetch_add(&local_queue_counter[queue_id], 1, __ATOMIC_RELAXED);
        int batch_idx = batch_start + (ticket % b_per_q);
        struct PacketBatch *batch = &batch_list[batch_idx];

        batch->num_pkts = 0;
        uint32_t valid_pkts = 0;

        // Parse each packet in the burst
        for (uint16_t i = 0; i < nb_rx; i++) {
            char *raw = rte_pktmbuf_mtod(pkts[i], char *);
            uint32_t len = rte_pktmbuf_pkt_len(pkts[i]);
            uint32_t hdr_offset = sizeof(struct rte_ether_hdr);

            // Skip packet if it is too small
            if (len <= hdr_offset) {
                rte_pktmbuf_free(pkts[i]);
                continue;
            }

            struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(raw + hdr_offset);
            hdr_offset += (ip->version_ihl & 0x0f) * 4;

            // Handle TCP or UDP headers to find the actual payload
            if (ip->next_proto_id == IPPROTO_TCP) {
                struct rte_tcp_hdr *tcp = (struct rte_tcp_hdr *)(raw + hdr_offset);
                hdr_offset += ((tcp->data_off & 0xf0) >> 4) * 4;
            } else if (ip->next_proto_id == IPPROTO_UDP) {
                hdr_offset += sizeof(struct rte_udp_hdr);
            } else {
                rte_pktmbuf_free(pkts[i]);
                continue;
            }

            uint32_t payload_len = (len > hdr_offset) ? len - hdr_offset : 0;
            if (payload_len > MAX_PAYLOAD_SIZE) payload_len = MAX_PAYLOAD_SIZE;

            // Copy payload data into the current batch buffer
            if (payload_len > 0) {
                char *dest = batch->packet_data + (valid_pkts * MAX_PAYLOAD_SIZE);
                memcpy(dest, raw + hdr_offset, payload_len);
                batch->lengths[valid_pkts] = payload_len;
                valid_pkts++;
            }

            // Free the DPDK mbuf memory
            rte_pktmbuf_free(pkts[i]);
        }

        // Push the batch into the shared ring queue for consumers
        if (valid_pkts > 0) {
            batch->num_pkts = valid_pkts;
            __atomic_store_n(&batch->in_use, 1, __ATOMIC_RELEASE);

            while (rte_ring_enqueue(ring, batch) < 0 && !__atomic_load_n(&stop_program, __ATOMIC_ACQUIRE)) {
                rte_pause();
            }
        } else {
            __atomic_store_n(&batch->in_use, 0, __ATOMIC_RELEASE);
        }
    }

    __atomic_store_n(&queue_done[queue_id], 1, __ATOMIC_RELEASE);
    return 0;
}

// Consumer thread: pulls packet batches from the ring and runs Aho-Corasick pattern matching on CPU
int packet_analysis_worker(void *arg) {
    struct ConsumerData *args = (struct ConsumerData *)arg;
    struct rte_ring *ring = args->queue;
    AC_Automata *ac_tree = args->ac_tree;

    // Loop until program stops and the ring queue is completely empty
    while (!__atomic_load_n(&stop_program, __ATOMIC_ACQUIRE) || !rte_ring_empty(ring)) {
        struct PacketBatch *batch = NULL;
        if (rte_ring_dequeue(ring, (void **)&batch) < 0) {
            rte_pause();
            continue;
        }

        // Scan every packet payload in the batch against the rules automaton
        for (uint32_t i = 0; i < batch->num_pkts; i++) {
            char *payload = batch->packet_data + (i * MAX_PAYLOAD_SIZE);
            uint32_t len = batch->lengths[i];
            args->matches_counter += ac_search_benchmark(ac_tree, payload, len);
        }

        // Mark the batch as free to use again
        __atomic_store_n(&batch->in_use, 0, __ATOMIC_RELEASE);
    }

    return 0;
}