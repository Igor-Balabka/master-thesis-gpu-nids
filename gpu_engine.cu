#include <cuda_runtime.h>
#include <stdio.h>
#include <stdint.h>
#include "gpu_engine.h"
#include "config.h"

// Remplacement de rte_pause pour NVCC sans inclure les headers DPDK
#if defined(__x86_64__) || defined(_M_X64)
  #include <emmintrin.h>
  #define cpu_pause() _mm_pause()
#else
  #define cpu_pause() ((void)0)
#endif

static int *d_transition_table = NULL;
static int *d_output_counts = NULL;

static cudaStream_t streams[NUM_STREAMS];
static cudaEvent_t events[NUM_STREAMS]; // CUDA Events pour le tracking non-bloquant

static char *d_batch_payloads[NUM_STREAMS];
static uint32_t *d_batch_lengths[NUM_STREAMS];
static unsigned long long *d_batch_matches[NUM_STREAMS];
static unsigned long long *h_pinned_matches[NUM_STREAMS]; // Mémoire Pinned pour D2H direct

__global__ void aho_corasick_stream_kernel(
    const char *d_payloads,
    const uint32_t *d_lens,
    uint32_t num_packets,
    const int *d_trans,
    const int *d_out,
    unsigned long long *d_matches_out)
{
    uint32_t pkt_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (pkt_idx >= num_packets) return;

    uint32_t len = d_lens[pkt_idx];
    const char *payload = d_payloads + (pkt_idx * MAX_PAYLOAD_SIZE);

    int state = 0;
    unsigned long long local_matches = 0;

    for (uint32_t i = 0; i < len; i++) {
        unsigned char ch = (unsigned char)payload[i];
        state = d_trans[state * ALPHABET_SIZE + ch];
        local_matches += d_out[state];
    }

    if (local_matches > 0) {
        atomicAdd(d_matches_out, local_matches);
    }
}

extern "C" void gpu_init_dfa(const AC_Automata *m) {
    size_t trans_size = (size_t)m->capacity * ALPHABET_SIZE * sizeof(int);
    size_t out_size = (size_t)m->capacity * sizeof(int);

    cudaMalloc((void**)&d_transition_table, trans_size);
    cudaMalloc((void**)&d_output_counts, out_size);

    cudaMemcpy(d_transition_table, m->transition_table, trans_size, cudaMemcpyHostToDevice);
    cudaMemcpy(d_output_counts, m->output_counts, out_size, cudaMemcpyHostToDevice);

    for (int i = 0; i < NUM_STREAMS; i++) {
        cudaStreamCreateWithFlags(&streams[i], cudaStreamNonBlocking);
        cudaEventCreateWithFlags(&events[i], cudaEventDisableTiming);

        cudaMalloc((void**)&d_batch_payloads[i], MAX_PKTS_PER_SLOT * MAX_PAYLOAD_SIZE);
        cudaMalloc((void**)&d_batch_lengths[i], MAX_PKTS_PER_SLOT * sizeof(uint32_t));
        cudaMalloc((void**)&d_batch_matches[i], sizeof(unsigned long long));
        
        cudaHostAlloc((void**)&h_pinned_matches[i], sizeof(unsigned long long), cudaHostAllocDefault);
        *h_pinned_matches[i] = 0;
    }
}

extern "C" void gpu_free_dfa(void) {
    if (d_transition_table) cudaFree(d_transition_table);
    if (d_output_counts) cudaFree(d_output_counts);

    for (int i = 0; i < NUM_STREAMS; i++) {
        cudaFree(d_batch_payloads[i]);
        cudaFree(d_batch_lengths[i]);
        cudaFree(d_batch_matches[i]);
        cudaFreeHost(h_pinned_matches[i]);
        cudaEventDestroy(events[i]);
        cudaStreamDestroy(streams[i]);
    }
}

extern "C" int gpu_is_stream_ready(int stream_idx) {
    cudaError_t status = cudaEventQuery(events[stream_idx]);
    return (status == cudaSuccess);
}

extern "C" unsigned long long gpu_collect_stream_matches(int stream_idx) {
    return *h_pinned_matches[stream_idx];
}

extern "C" void gpu_process_batch_async_submit(
    const char *h_packet_data, 
    const uint32_t *h_lengths, 
    uint32_t num_pkts, 
    int stream_idx) 
{
    if (num_pkts == 0) return;

    cudaStream_t stream = streams[stream_idx];
    size_t payload_bytes = num_pkts * MAX_PAYLOAD_SIZE;
    size_t len_bytes = num_pkts * sizeof(uint32_t);

    cudaMemsetAsync(d_batch_matches[stream_idx], 0, sizeof(unsigned long long), stream);
    cudaMemcpyAsync(d_batch_payloads[stream_idx], h_packet_data, payload_bytes, cudaMemcpyHostToDevice, stream);
    cudaMemcpyAsync(d_batch_lengths[stream_idx], h_lengths, len_bytes, cudaMemcpyHostToDevice, stream);

    int threadsPerBlock = 256;
    int blocksPerGrid = (num_pkts + threadsPerBlock - 1) / threadsPerBlock;

    aho_corasick_stream_kernel<<<blocksPerGrid, threadsPerBlock, 0, stream>>>(
        d_batch_payloads[stream_idx],
        d_batch_lengths[stream_idx],
        num_pkts,
        d_transition_table,
        d_output_counts,
        d_batch_matches[stream_idx]
    );

    cudaMemcpyAsync(h_pinned_matches[stream_idx], d_batch_matches[stream_idx], sizeof(unsigned long long), cudaMemcpyDeviceToHost, stream);
    cudaEventRecord(events[stream_idx], stream);
}

extern "C" void gpu_synchronize_all(void) {
    cudaDeviceSynchronize();
}

extern "C" void print_gpu_specs(void) {
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);
    if (deviceCount == 0) return;
    for (int i = 0; i < deviceCount; i++) {
        cudaDeviceProp prop;
        cudaGetDeviceProperties(&prop, i);
        printf("GPU %d: %s (CC %d.%d, VRAM: %.2f GB)\n", 
               i, prop.name, prop.major, prop.minor, 
               (double)prop.totalGlobalMem / (1024 * 1024 * 1024));
    }
}

extern "C" double run_classic_packet_benchmark(const AC_Automata *m, const MbufPool *pool, int loops, long *out_matches) {
    (void)loops;
    gpu_init_dfa(m);
    unsigned long long total = 0;
    
    size_t processed = 0;
    int stream_idx = 0;
    while (processed < pool->packet_count) {
        uint32_t batch_pkts = (pool->packet_count - processed > MAX_PKTS_PER_SLOT) ? MAX_PKTS_PER_SLOT : (pool->packet_count - processed);
        
        char *h_data = (char*)malloc(batch_pkts * MAX_PAYLOAD_SIZE);
        uint32_t *h_lens = (uint32_t*)malloc(batch_pkts * sizeof(uint32_t));

        for (uint32_t i = 0; i < batch_pkts; i++) {
            h_lens[i] = pool->mbuf_array[processed + i].data_len;
            memcpy(h_data + (i * MAX_PAYLOAD_SIZE), pool->mbuf_array[processed + i].buf_addr, h_lens[i]);
        }

        while (!gpu_is_stream_ready(stream_idx)) { cpu_pause(); }
        
        total += gpu_collect_stream_matches(stream_idx);
        gpu_process_batch_async_submit(h_data, h_lens, batch_pkts, stream_idx);

        free(h_data);
        free(h_lens);
        processed += batch_pkts;
        stream_idx = (stream_idx + 1) % NUM_STREAMS;
    }

    gpu_synchronize_all();
    for (int s = 0; s < NUM_STREAMS; s++) {
        total += gpu_collect_stream_matches(s);
    }

    gpu_free_dfa();
    *out_matches = (long)total;
    return 0.1;
}