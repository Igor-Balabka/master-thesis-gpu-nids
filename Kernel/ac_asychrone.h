#ifndef AC_DOUBLE_BUFFERING_H
#define AC_DOUBLE_BUFFERING_H

#include "../ac.h"
#include "../payload.h"

#ifdef __cplusplus
extern "C"
{
#endif

    /**
     * Main benchmark function for the GPU Asynchronous engine.
     * @param m                  Pointer to the Aho-Corasick machine
     * @param pool               The MbufPool containing the packet payloads
     * @param loops              Number of times to repeat the test
     * @param out_matches        Pointer to store the total number of matches found
     * @param block_size         Cuda block size
     * @param batch_size         Number of packets send in the stream
     * @param n_slots            Number of concurrent CUDA streams to use
     * @return The average execution time in seconds.
     */
    double run_mbuf_benchmark(
        const AC_Automata *m,
        MbufPool *pool,
        int loops,
        long *out_matches,
        int block_size,
        int batch_size,
        int n_slots);

#ifdef __cplusplus
}
#endif

#endif