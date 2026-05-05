#ifndef AC_DOUBLE_BUFFERING_H
#define AC_DOUBLE_BUFFERING_H

#include "../ac.h"
#include "../payload.h"

#ifdef __cplusplus
extern "C" {
#endif

double run_mbuf_benchmark(
    const AC_Machine *m, 
    MbufPool *pool, 
    int loops, 
    long *out_matches, 
    int threads_per_block, 
    int batch_size, 
    int n_slots
);

#ifdef __cplusplus
}
#endif

#endif