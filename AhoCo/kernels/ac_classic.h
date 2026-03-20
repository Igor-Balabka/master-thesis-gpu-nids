#ifndef AC_CLASSIC_H
#define AC_CLASSIC_H

#include "ac.h"

//void ac_classic_kernel(int *d_table, int *d_output_counts, char *d_payload, long *d_packet_start, int *d_packet_lengths, int num_packets, long *d_results) ;

double run_classic_packet_benchmark(const AC_Machine *m, const char *payload, long *packet_start, int *packet_lengths, int num_packets, int loops, long *out_matches);

#endif