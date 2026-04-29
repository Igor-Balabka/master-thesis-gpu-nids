#ifndef AC_DOUBLE_BUFFERING_H
#define AC_DOUBLE_BUFFERING_H

#include "../ac.h"

#ifdef __cplusplus
extern "C" {
#endif

double run_buffering_packet_benchmark(const AC_Machine *m, const char *payload, 
                                      unsigned long *packet_offsets, int *packet_lengths, 
                                      int num_packets, int loops, long *out_matches, 
                                      int threads_per_block, int batch_size, int n_slots);

#ifdef __cplusplus
}
#endif

#endif