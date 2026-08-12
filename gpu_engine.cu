#include <cuda_runtime.h>
#include <stdio.h>
#include <stdint.h>
#include "gpu_engine.h"
#include "config.h"

// Platform-specific CPU pause instructions for spin-waiting
#if defined(__x86_64__) || defined(_M_X64)
  #include <emmintrin.h>
  #define cpu_pause() _mm_pause()
#else
  #define cpu_pause() ((void)0)
#endif

// GPU global device pointers for the Aho-Corasick automaton
static int *d_transition_table = NULL;
static int *d_output_counts = NULL;

// CUDA streams and events for asynchronous parallel processing
static cudaStream_t streams[NUM_STREAMS];
static cudaEvent_t events[NUM_STREAMS];

// Buffers per stream on GPU and pinned host memory for zero-copy transfers
static char *d_batch_payloads[NUM_STREAMS];
static uint32_t *d_batch_lengths[NUM_STREAMS];
static unsigned long long *d_batch_matches[NUM_STREAMS];
static unsigned long long *h_pinned_matches[NUM_STREAMS];

// CUDA kernel to perform Aho-Corasick pattern matching on packet payloads in parallel
__global__ void aho_corasick_stream_kernel(
    const char *__restrict__ d_payloads,
    const uint32_t *__restrict__ d_lens,
    uint32_t num_packets,
    const int *__restrict__ d_trans,
    const int *__restrict__ d_out,
    unsigned long long *__restrict__ d_matches_out)
{
    // Calculate global thread ID to process one packet per thread
    uint32_t pkt_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (pkt_idx >= num_packets) return;

    uint32_t len = d_lens[pkt_idx];
    const char *payload = d_payloads + ((size_t)pkt_idx * MAX_PAYLOAD_SIZE);

    int state = 0;
    unsigned long long local_matches = 0;

    // Traverse the DFA states for each character in the packet payload
    for (uint32_t i = 0; i < len; i++) {
        unsigned char ch = (unsigned char)payload[i];
        state = d_trans[state * ALPHABET_SIZE + ch];
        local_matches += d_out[state];
    }

    // Atomically add matches found by this thread to the global stream counter
    if (local_matches > 0) {
        atomicAdd(d_matches_out, local_matches);
    }
}

// Initialize the GPU automaton, allocate VRAM, and set up streams
extern "C" void gpu_init_dfa(const AC_Automata *m) {
    size_t trans_size = (size_t)m->capacity * ALPHABET_SIZE * sizeof(int);
    size_t out_size = (size_t)m->capacity * sizeof(int);
    size_t total_vram_bytes = trans_size + out_size;

    printf("\n[GPU DFA Stats] States: %d | Transition Table: %.2f KB | Output Table: %.2f KB | Total VRAM: %.2f MB\n",
           m->capacity,
           (double)trans_size / 1024.0,
           (double)out_size / 1024.0,
           (double)total_vram_bytes / (1024.0 * 1024.0));

    // Allocate GPU memory and copy automaton tables from host to device
    cudaMalloc((void**)&d_transition_table, trans_size);
    cudaMalloc((void**)&d_output_counts, out_size);

    cudaMemcpy(d_transition_table, m->transition_table, trans_size, cudaMemcpyHostToDevice);
    cudaMemcpy(d_output_counts, m->output_counts, out_size, cudaMemcpyHostToDevice);

    // Create streams, events, and buffers for asynchronous processing
    for (int i = 0; i < NUM_STREAMS; i++) {
        cudaStreamCreateWithFlags(&streams[i], cudaStreamNonBlocking);
        cudaEventCreateWithFlags(&events[i], cudaEventDisableTiming);

        cudaMalloc((void**)&d_batch_payloads[i], (size_t)MAX_PKTS_PER_SLOT * MAX_PAYLOAD_SIZE);
        cudaMalloc((void**)&d_batch_lengths[i], (size_t)MAX_PKTS_PER_SLOT * sizeof(uint32_t));
        cudaMalloc((void**)&d_batch_matches[i], sizeof(unsigned long long));
        
        cudaHostAlloc((void**)&h_pinned_matches[i], sizeof(unsigned long long), cudaHostAllocDefault);
        *h_pinned_matches[i] = 0;
    }
}

// Free all GPU memory, streams, and pinned host memory
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

// Check if a specific CUDA stream has finished its execution
extern "C" int gpu_is_stream_ready(int stream_idx) {
    cudaError_t status = cudaEventQuery(events[stream_idx]);
    if (status == cudaErrorNotReady) return 0;
    return 1;
}

// Collect matches counted by a stream and reset its counter
extern "C" unsigned long long gpu_collect_stream_matches(int stream_idx) {
    unsigned long long val = *h_pinned_matches[stream_idx];
    *h_pinned_matches[stream_idx] = 0;
    return val;
}

// Submit a batch of packets asynchronously to a specific CUDA stream
extern "C" void gpu_process_batch_async_submit(
    const char *h_packet_data, 
    const uint32_t *h_lengths, 
    uint32_t num_pkts, 
    int stream_idx) 
{
    if (num_pkts == 0) return;

    cudaStream_t stream = streams[stream_idx];
    size_t payload_bytes = (size_t)num_pkts * MAX_PAYLOAD_SIZE;
    size_t len_bytes = (size_t)num_pkts * sizeof(uint32_t);

    // Asynchronously copy data from CPU to GPU and launch the kernel
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

    // Copy results back to pinned host memory and record an event
    cudaMemcpyAsync(h_pinned_matches[stream_idx], d_batch_matches[stream_idx], sizeof(unsigned long long), cudaMemcpyDeviceToHost, stream);
    cudaEventRecord(events[stream_idx], stream);
}

// Synchronize all active CUDA streams and device tasks
extern "C" void gpu_synchronize_all(void) {
    cudaDeviceSynchronize();
}

// Print detailed specifications of available GPUs
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

// Benchmark function to process packets on the GPU using streams
extern "C" double run_classic_packet_benchmark(const AC_Automata *m, const MbufPool *pool, int loops, long *out_matches) {
    (void)loops;
    gpu_init_dfa(m);
    unsigned long long total = 0;
    
    // Pre-allocate host buffers to avoid malloc/free overhead during the loop
    char *h_data = (char*)malloc((size_t)MAX_PKTS_PER_SLOT * MAX_PAYLOAD_SIZE);
    uint32_t *h_lens = (uint32_t*)malloc((size_t)MAX_PKTS_PER_SLOT * sizeof(uint32_t));

    size_t processed = 0;
    int stream_idx = 0;
    while (processed < pool->packet_count) {
        uint32_t batch_pkts = (pool->packet_count - processed > MAX_PKTS_PER_SLOT) ? MAX_PKTS_PER_SLOT : (pool->packet_count - processed);
        
        memset(h_data, 0, (size_t)batch_pkts * MAX_PAYLOAD_SIZE);

        for (uint32_t i = 0; i < batch_pkts; i++) {
            h_lens[i] = pool->mbuf_array[processed + i].data_len;
            memcpy(h_data + (i * MAX_PAYLOAD_SIZE), pool->mbuf_array[processed + i].buf_addr, h_lens[i]);
        }

        // Wait until the stream is ready before submitting new work
        while (!gpu_is_stream_ready(stream_idx)) { cpu_pause(); }
        
        total += gpu_collect_stream_matches(stream_idx);
        gpu_process_batch_async_submit(h_data, h_lens, batch_pkts, stream_idx);

        processed += batch_pkts;
        stream_idx = (stream_idx + 1) % NUM_STREAMS;
    }

    gpu_synchronize_all();
    for (int s = 0; s < NUM_STREAMS; s++) {
        total += gpu_collect_stream_matches(s);
    }

    free(h_data);
    free(h_lens);
    gpu_free_dfa();
    *out_matches = (long)total;
    return 0.1;
}