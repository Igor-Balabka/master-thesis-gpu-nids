#ifndef AC_CLASSIC_H
#define AC_CLASSIC_H

#include "../ac.h"
#include "../payload.h"

#ifdef __cplusplus
extern "C"
{
#endif

    /**
     * Executes the baseline Aho-Corasick benchmark on the GPU.
     * * This version uses a synchronous approach. It copies all data to the
     * device memory first, and then launches the kernel.
     * It is used as a performance baseline to compare against the asynchronous version.
     * @param m            Pointer to the Aho-Corasick machine
     * @param pool         The MbufPool containing the packets to scan
     * @param loops        Number of benchmark iterations
     * @param out_matches  Pointer to store the total number of patterns found
     * * @return The average execution time of the kernel in seconds.
     */
    double run_classic_packet_benchmark(const AC_Automata *m, MbufPool *pool, int loops, long *out_matches);

#ifdef __cplusplus
}
#endif

#endif