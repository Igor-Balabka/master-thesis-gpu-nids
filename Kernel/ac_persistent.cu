#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "../ac.h"
#include "ac_asychrone.h"
#include "cuda_utils.h"
#include "payload.h"
#include <unistd.h>

// Flags in global memory
__device__ volatile int d_data_ready = 0;      
__device__ volatile int d_blocks_finished = 0; 

__device__ int d_batch_offset_pkts = 0;
__device__ int d_n_pkts_this_batch = 0;

__global__ void ac_persistent_kernel(
    const int *__restrict__ d_table,
    const int *__restrict__ d_output_counts,
    const char *__restrict__ d_payload,
    const unsigned long *__restrict__ d_packet_start,
    const int *__restrict__ d_packet_lengths,
    long *d_results,
    volatile int *flag_h2d,         // Host -> GPU : 1=go, -1=stop
    volatile int *flag_d2h,         // GPU -> Host : 2=done
    volatile int *d_batch_offset,   
    volatile int *d_n_pkts,         
    volatile int *d_blocks_done)    
{
    int local_tid   = threadIdx.x;
    int global_tid  = blockIdx.x * blockDim.x + threadIdx.x;
    int grid_stride = blockDim.x * gridDim.x;
    int num_blocks  = gridDim.x;

    while (1)
    {
        // 1. Attente du signal CPU
        if (local_tid == 0) {
            int v;
            do {
                v = *flag_h2d;
                __threadfence_system();
            } while (v == 0);
        }
        __syncthreads(); 

        __shared__ int s_sig;
        if (local_tid == 0) {
            s_sig = *flag_h2d;
        }
        __syncthreads();

        // Check Terminaison
        if (s_sig == -1) {
            break;
        }


        __shared__ int s_offset;
        __shared__ int s_npkts;
        if (local_tid == 0) {
            s_offset = *d_batch_offset;
            s_npkts  = *d_n_pkts;
        }
        __syncthreads();

        int batch_offset = s_offset;
        int n_pkts       = s_npkts;

        // 2. Calcul du Batch
        for (int pkt_idx_local = global_tid; pkt_idx_local < n_pkts; pkt_idx_local += grid_stride)
        {
            long pkt_idx = (long)batch_offset + pkt_idx_local;
            unsigned long start = d_packet_start[pkt_idx];
            int len = d_packet_lengths[pkt_idx];

            int state   = 0;
            long matches = 0;
            const unsigned char *p = (const unsigned char *)d_payload;

            for (int j = 0; j < len; j++) {
                unsigned char c = p[start + j];
                state   = __ldg(&d_table[state * 256 + c]);
                matches += __ldg(&d_output_counts[state]);
            }
            d_results[pkt_idx] = matches;
        }

        __syncthreads();

        // 3. Coordination de fin de lot
        if (local_tid == 0) {
            __threadfence(); 

            int ticket = atomicAdd((int*)d_blocks_done, 1);

            if (ticket == num_blocks - 1) {
                // JE SUIS LE DERNIER BLOC

                *d_blocks_done = 0;        
                __threadfence_system();    
                *flag_d2h = 2;             
                __threadfence_system();

                while (*flag_h2d != 0) {
                    __threadfence_system();
                }
            } else {

                
                while (*flag_h2d != 0) {
                    __threadfence_system();
                }
            }
        }
        __syncthreads();
    }
}

extern "C"
{
    double run_persistent_benchmark(
        const AC_Automata *m, MbufPool *pool, int loops, long *out_matches,
        int block_size, int batch_size, int n_slots)
    {
        int num_packets = pool->packet_count;
        if (num_packets <= 0) return 0.0;

        size_t total_data_size = pool->total_bytes;

        unsigned long *h_packet_start = (unsigned long *)malloc(num_packets * sizeof(unsigned long));
        int *h_packet_lengths         = (int *)malloc(num_packets * sizeof(int));
        prepare_packet_metadata(pool, h_packet_start, h_packet_lengths);

        char *pinned_payload = (char *)pool->mempool_data;

        int *d_table, *d_output_counts;
        char *d_payload;
        unsigned long *d_packet_start;
        int *d_packet_lengths;
        long *d_results;

        CUDA_CHECK(cudaMalloc(&d_table,          (size_t)m->capacity * 256 * sizeof(int)));
        CUDA_CHECK(cudaMalloc(&d_output_counts,  (size_t)m->capacity * sizeof(int)));
        CUDA_CHECK(cudaMalloc(&d_payload,         total_data_size));
        CUDA_CHECK(cudaMalloc(&d_packet_start,   (size_t)num_packets * sizeof(unsigned long)));
        CUDA_CHECK(cudaMalloc(&d_packet_lengths, (size_t)num_packets * sizeof(int)));
        CUDA_CHECK(cudaMalloc(&d_results,        (size_t)num_packets * sizeof(long)));

        CUDA_CHECK(cudaMemcpy(d_table, m->transition_table, (size_t)m->capacity * 256 * sizeof(int), cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_output_counts, m->output_counts, (size_t)m->capacity * sizeof(int), cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_packet_start, h_packet_start, (size_t)num_packets * sizeof(unsigned long), cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_packet_lengths, h_packet_lengths, (size_t)num_packets * sizeof(int), cudaMemcpyHostToDevice));

        volatile int *h_flag_h2d, *h_flag_d2h;
        volatile int *h_batch_offset, *h_n_pkts, *h_blocks_done;
        int *d_flag_h2d, *d_flag_d2h;
        int *d_batch_offset_ptr, *d_n_pkts_ptr, *d_blocks_done_ptr;

        CUDA_CHECK(cudaHostAlloc((void**)&h_flag_h2d,     sizeof(int), cudaHostAllocMapped));
        CUDA_CHECK(cudaHostAlloc((void**)&h_flag_d2h,     sizeof(int), cudaHostAllocMapped));
        CUDA_CHECK(cudaHostAlloc((void**)&h_batch_offset, sizeof(int), cudaHostAllocMapped));
        CUDA_CHECK(cudaHostAlloc((void**)&h_n_pkts,       sizeof(int), cudaHostAllocMapped));
        CUDA_CHECK(cudaHostAlloc((void**)&h_blocks_done,  sizeof(int), cudaHostAllocMapped));

        CUDA_CHECK(cudaHostGetDevicePointer((void**)&d_flag_h2d,         (void*)h_flag_h2d,     0));
        CUDA_CHECK(cudaHostGetDevicePointer((void**)&d_flag_d2h,         (void*)h_flag_d2h,     0));
        CUDA_CHECK(cudaHostGetDevicePointer((void**)&d_batch_offset_ptr, (void*)h_batch_offset, 0));
        CUDA_CHECK(cudaHostGetDevicePointer((void**)&d_n_pkts_ptr,       (void*)h_n_pkts,       0));
        CUDA_CHECK(cudaHostGetDevicePointer((void**)&d_blocks_done_ptr,  (void*)h_blocks_done,  0));

        *h_flag_h2d     = 0;
        *h_flag_d2h     = 0;
        *h_batch_offset = 0;
        *h_n_pkts       = 0;
        *h_blocks_done  = 0;

        cudaStream_t stream_kernel, stream_copy;
        CUDA_CHECK(cudaStreamCreateWithFlags(&stream_kernel, cudaStreamNonBlocking));
        CUDA_CHECK(cudaStreamCreateWithFlags(&stream_copy, cudaStreamNonBlocking));

        int sm_count = 0;
        CUDA_CHECK(cudaDeviceGetAttribute(&sm_count, cudaDevAttrMultiProcessorCount, 0));
        int blocks = sm_count; 


        ac_persistent_kernel<<<blocks, block_size, 0, stream_kernel>>>(
            d_table, d_output_counts, d_payload,
            d_packet_start, d_packet_lengths, d_results,
            (volatile int*)d_flag_h2d, (volatile int*)d_flag_d2h,
            (volatile int*)d_batch_offset_ptr, (volatile int*)d_n_pkts_ptr,
            (volatile int*)d_blocks_done_ptr
        );

        for (volatile int spin = 0; spin < 100000; spin++);
        //usleep(10000);

        cudaEvent_t start_ev, stop_ev;
        CUDA_CHECK(cudaEventCreate(&start_ev));
        CUDA_CHECK(cudaEventCreate(&stop_ev));
        CUDA_CHECK(cudaEventRecord(start_ev, 0));

        for (int l = 0; l < loops; l++)
        {
            for (int i = 0; i < num_packets; i += batch_size)
            {
                int n_pkts = (i + batch_size > num_packets) ? (num_packets - i) : batch_size;

                unsigned long batch_offset = h_packet_start[i];
                size_t last_idx            = i + n_pkts - 1;
                size_t batch_end           = (size_t)h_packet_start[last_idx] + (size_t)h_packet_lengths[last_idx];
                size_t batch_payload_size  = batch_end - batch_offset;

                CUDA_CHECK(cudaMemcpyAsync(
                    d_payload + batch_offset,
                    pinned_payload + batch_offset,
                    batch_payload_size,
                    cudaMemcpyHostToDevice,
                    stream_copy));
                CUDA_CHECK(cudaStreamSynchronize(stream_copy));

                *h_batch_offset = i;
                *h_n_pkts       = n_pkts;
                *h_flag_d2h     = 0;
                __sync_synchronize();

                *h_flag_h2d = 1;

                while (*h_flag_d2h != 2) {
                    __sync_synchronize();
                }

                *h_flag_h2d = 0;
                __sync_synchronize();
            }
        }

        CUDA_CHECK(cudaEventRecord(stop_ev, 0));
        CUDA_CHECK(cudaEventSynchronize(stop_ev));

        float ms = 0;
        CUDA_CHECK(cudaEventElapsedTime(&ms, start_ev, stop_ev));

        *h_flag_h2d = -1;
        __sync_synchronize();
        CUDA_CHECK(cudaDeviceSynchronize());

        long *h_results = (long *)malloc((size_t)num_packets * sizeof(long));
        CUDA_CHECK(cudaMemcpy(h_results, d_results, (size_t)num_packets * sizeof(long), cudaMemcpyDeviceToHost));

        long total = 0;
        for (int i = 0; i < num_packets; i++) {
            total += h_results[i];
        }
        *out_matches = total;

        free(h_packet_start);
        free(h_packet_lengths);
        free(h_results);

        cleanup_gpu(d_table, d_output_counts, d_payload, d_packet_start, d_packet_lengths, d_results, NULL, 0);

        CUDA_CHECK(cudaFreeHost((void*)h_flag_h2d));
        CUDA_CHECK(cudaFreeHost((void*)h_flag_d2h));
        CUDA_CHECK(cudaFreeHost((void*)h_batch_offset));
        CUDA_CHECK(cudaFreeHost((void*)h_n_pkts));
        CUDA_CHECK(cudaFreeHost((void*)h_blocks_done));

        CUDA_CHECK(cudaStreamDestroy(stream_kernel));
        CUDA_CHECK(cudaStreamDestroy(stream_copy));
        CUDA_CHECK(cudaEventDestroy(start_ev));
        CUDA_CHECK(cudaEventDestroy(stop_ev));

        return (double)ms / 1000.0 / loops;
    }
}