#ifndef AC_CLASSIC_H
#define AC_CLASSIC_H

#include "../ac.h"
#include "../payload.h"

#ifdef __cplusplus
extern "C" {
#endif

double run_classic_packet_benchmark(const AC_Machine *m, MbufPool *pool, int loops, long *out_matches);



#ifdef __cplusplus
}
#endif

#endif