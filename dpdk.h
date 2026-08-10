#ifndef DPDK_H
#define DPDK_H

#include <stdint.h>
#include <rte_ring.h>
#include "config.h"
#include "ac.h"

extern volatile int port_started;
extern volatile int stop_program;
extern volatile int queue_done[RTE_MAX_LCORE];
extern int g_batches_per_queue; // Allocation dynamique de batches par queue

struct ProducerData {
    uint16_t port_id;
    uint16_t queue_id;
    struct rte_ring *queue;
    struct PacketBatch *batch_list;
    int total_batches;
};

struct ConsumerData {
    struct rte_ring *queue;
    AC_Automata *ac_tree;
    unsigned long long matches_counter;
};

int packet_capture_worker(void *arg);
int packet_analysis_worker(void *arg);
int all_queues_done(uint16_t nb_queues);

#endif // DPDK_H