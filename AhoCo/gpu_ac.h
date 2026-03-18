#ifndef GPU_AC_H
#define GPU_AC_H

#include "ac.h"


#ifdef __cplusplus
extern "C" {
#endif

double run_gpu_packet_benchmark(const AC_Machine *m, 
                                const char *payload, 
                                long *packet_offsets, 
                                int *packet_lengths, 
                                int num_packets, 
                                int loops, 
                                long *out_matches);

#ifdef __cplusplus
}
#endif

#endif