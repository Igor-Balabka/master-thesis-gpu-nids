#ifndef AC_CLASSIC_H
#define AC_CLASSIC_H

#include "../ac.h"

#ifdef __cplusplus
extern "C" {
#endif

double run_classic_packet_benchmark(const AC_Machine *m, const char *payload, 
                                    unsigned long *packet_start, int *packet_lengths, 
                                    int num_packets, int loops, long *out_matches);

#ifdef __cplusplus
}
#endif

#endif