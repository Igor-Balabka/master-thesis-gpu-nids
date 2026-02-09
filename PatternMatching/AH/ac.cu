#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cuda_runtime.h>

#define ALPHABET_SIZE 256
#define MAX_ALERTS 10000 // Max size of GPU result buffer

// --- 1. STRUCTURES (CPU & GPU) ---

// Temporary structure for construction (CPU only)
typedef struct OutputNode {
    int pattern_id;
    struct OutputNode *next;
} OutputNode;

// The Aho-Corasick Machine (CPU Version)
typedef struct {
    int *transition_table; 
    int *output_counts;
    int *output_indexes; 
    int *output_list;
    int total_outputs;
    int num_states;
    int max_states;
    OutputNode **temp_outputs; 
} AC_Machine;

// Structure to retrieve results from GPU
typedef struct {
    int packet_id;  // Which packet?
    int pattern_id; // Which rule?
    int position;   // Where?
} Alert;

// --- 2. CPU FUNCTIONS (Automaton Construction) ---
// These functions remain on the CPU because construction is sequential.

AC_Machine* ac_create(int max_states) {
    AC_Machine *m = (AC_Machine*)malloc(sizeof(AC_Machine));
    m->max_states = max_states;
    m->num_states = 1;
    
    m->transition_table = (int*)malloc(max_states * ALPHABET_SIZE * sizeof(int));
    memset(m->transition_table, -1, max_states * ALPHABET_SIZE * sizeof(int));
    
    m->output_counts = (int*)calloc(max_states, sizeof(int));
    m->output_indexes = (int*)malloc(max_states * sizeof(int));
    m->output_list = NULL;
    m->temp_outputs = (OutputNode**)calloc(max_states, sizeof(OutputNode*));
    return m;
}

void _add_temp_output(AC_Machine *m, int state, int pattern_id) {
    OutputNode *head = m->temp_outputs[state];
    OutputNode *curr = head;
    while (curr) { if (curr->pattern_id == pattern_id) return; curr = curr->next; }
    OutputNode *newNode = (OutputNode*)malloc(sizeof(OutputNode));
    newNode->pattern_id = pattern_id;
    newNode->next = head;
    m->temp_outputs[state] = newNode;
}

void ac_add_pattern(AC_Machine *m, const char *pattern, int pattern_id) {
    int current_state = 0;
    int len = strlen(pattern);
    for (int i = 0; i < len; ++i) {
        unsigned char ch = (unsigned char)pattern[i];
        int idx = current_state * ALPHABET_SIZE + ch;
        if (m->transition_table[idx] == -1) {
            int new_state = m->num_states++;
            memset(&m->transition_table[new_state * ALPHABET_SIZE], -1, ALPHABET_SIZE * sizeof(int));
            m->transition_table[idx] = new_state;
        }
        current_state = m->transition_table[idx];
    }
    _add_temp_output(m, current_state, pattern_id);
}

void ac_finalize(AC_Machine *m) {
    int *q = (int*)malloc(m->max_states * sizeof(int));
    int head = 0, tail = 0;
    int *fail = (int*)calloc(m->max_states, sizeof(int)); 

    for (int ch = 0; ch < ALPHABET_SIZE; ++ch) {
        int idx = 0 * ALPHABET_SIZE + ch;
        if (m->transition_table[idx] == -1) m->transition_table[idx] = 0; 
        else {
            int state = m->transition_table[idx];
            fail[state] = 0; 
            q[tail++] = state;
        }
    }
    
    while (head < tail) {
        int state = q[head++];
        OutputNode *fail_outputs = m->temp_outputs[fail[state]];
        while (fail_outputs) {
            _add_temp_output(m, state, fail_outputs->pattern_id);
            fail_outputs = fail_outputs->next;
        }
        for (int ch = 0; ch < ALPHABET_SIZE; ++ch) {
            int trans_idx = state * ALPHABET_SIZE + ch;
            int next_state = m->transition_table[trans_idx];
            if (next_state != -1) {
                fail[next_state] = m->transition_table[fail[state] * ALPHABET_SIZE + ch];
                q[tail++] = next_state;
            } else {
                m->transition_table[trans_idx] = m->transition_table[fail[state] * ALPHABET_SIZE + ch];
            }
        }
    }
    free(q); free(fail);

    int total_outputs = 0;
    for (int i = 0; i < m->num_states; i++) {
        int count = 0;
        OutputNode *curr = m->temp_outputs[i];
        while (curr) { count++; curr = curr->next; }
        m->output_counts[i] = count;
        total_outputs += count;
    }
    m->total_outputs = total_outputs;
    
    if (total_outputs > 0) m->output_list = (int*)malloc(total_outputs * sizeof(int));
    
    int current_idx = 0;
    for (int i = 0; i < m->num_states; i++) {
        m->output_indexes[i] = current_idx;
        OutputNode *curr = m->temp_outputs[i];
        while (curr) {
            m->output_list[current_idx++] = curr->pattern_id;
            curr = curr->next;
        }
    }
    // Temporary cleanup omitted for brevity (should do a recursive free here)
}

// --- 3. THE CUDA KERNEL (GPU) ---

__global__ void ac_search_kernel(
    const char* all_packets,      // All packets concatenated
    const int* packet_offsets,    // Where each packet starts
    const int* packet_lengths,    // Size of each packet
    int num_packets,
    
    // The Automaton (Read Only)
    const int* transition_table,
    const int* output_counts,
    const int* output_indexes,
    const int* output_list,
    
    // Results (Write)
    Alert* alerts,
    int* alert_count
) {
    // Calculate thread ID (1 Thread = 1 Packet)
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    
    if (tid >= num_packets) return;

    int start = packet_offsets[tid];
    int len = packet_lengths[tid];
    int current_state = 0;

    for (int i = 0; i < len; ++i) {
        unsigned char ch = (unsigned char)all_packets[start + i];
        
        // 1. DFA Transition (O(1))
        // __ldg forces read through Read-Only Cache (faster for constants)
        current_state = __ldg(&transition_table[current_state * ALPHABET_SIZE + ch]);
        
        // 2. CSR Verification
        int count = __ldg(&output_counts[current_state]);
        
        if (count > 0) {
            int start_idx = __ldg(&output_indexes[current_state]);
            
            for (int k = 0; k < count; k++) {
                int pattern_id = __ldg(&output_list[start_idx + k]);
                
                // Atomic write of result
                int pos = atomicAdd(alert_count, 1);
                if (pos < MAX_ALERTS) {
                    alerts[pos].packet_id = tid;
                    alerts[pos].pattern_id = pattern_id;
                    alerts[pos].position = i;
                }
            }
        }
    }
}

// --- 4. MAIN ---

int main() {
    // --- A. CPU CONSTRUCTION ---
    printf("1. CPU: Building the automaton...\n");
    AC_Machine *host_machine = ac_create(1000);
    ac_add_pattern(host_machine, "he", 101);
    ac_add_pattern(host_machine, "she", 500);
    ac_add_pattern(host_machine, "his", 999);
    ac_add_pattern(host_machine, "hers", 42); 
    ac_finalize(host_machine);
    printf("   -> Automaton ready. %d states.\n", host_machine->num_states);

    // --- B. PACKET PREPARATION (Simulation) ---
    // For GPU, we concatenate everything into one large char array
    int num_packets = 3;
    const char* p1 = "ahishers";               // Contains everything
    const char* p2 = "nothinghere";            // Contains "he", "hers" (partial) -> "he"
    const char* p3 = "she is here";            // Contains "she", "he"
    
    int total_len = strlen(p1) + strlen(p2) + strlen(p3);
    
    char* h_all_packets = (char*)malloc(total_len);
    int* h_offsets = (int*)malloc(num_packets * sizeof(int));
    int* h_lengths = (int*)malloc(num_packets * sizeof(int));

    // Manual filling
    int offset = 0;
    
    // Packet 0
    h_offsets[0] = offset; h_lengths[0] = strlen(p1);
    memcpy(h_all_packets + offset, p1, strlen(p1)); offset += strlen(p1);
    
    // Packet 1
    h_offsets[1] = offset; h_lengths[1] = strlen(p2);
    memcpy(h_all_packets + offset, p2, strlen(p2)); offset += strlen(p2);
    
    // Packet 2
    h_offsets[2] = offset; h_lengths[2] = strlen(p3);
    memcpy(h_all_packets + offset, p3, strlen(p3)); offset += strlen(p3);

    // --- C. GPU ALLOCATION ---
    printf("2. GPU: Allocation and Copy...\n");
    
    char *d_packets;
    int *d_offsets, *d_lengths;
    int *d_trans, *d_counts, *d_indexes, *d_list;
    Alert *d_alerts;
    int *d_alert_count;

    // Packet Allocation
    cudaMalloc(&d_packets, total_len);
    cudaMalloc(&d_offsets, num_packets * sizeof(int));
    cudaMalloc(&d_lengths, num_packets * sizeof(int));
    
    // Automaton Allocation (Exact sizes extracted from CPU machine)
    int size_trans = host_machine->max_states * ALPHABET_SIZE * sizeof(int);
    int size_csr_meta = host_machine->max_states * sizeof(int);
    int size_csr_data = host_machine->total_outputs * sizeof(int);

    cudaMalloc(&d_trans, size_trans);
    cudaMalloc(&d_counts, size_csr_meta);
    cudaMalloc(&d_indexes, size_csr_meta);
    if (size_csr_data > 0) cudaMalloc(&d_list, size_csr_data);
    
    // Results Allocation
    cudaMalloc(&d_alerts, MAX_ALERTS * sizeof(Alert));
    cudaMalloc(&d_alert_count, sizeof(int));

    // --- D. HOST -> DEVICE COPY ---
    cudaMemcpy(d_packets, h_all_packets, total_len, cudaMemcpyHostToDevice);
    cudaMemcpy(d_offsets, h_offsets, num_packets * sizeof(int), cudaMemcpyHostToDevice);
    cudaMemcpy(d_lengths, h_lengths, num_packets * sizeof(int), cudaMemcpyHostToDevice);

    cudaMemcpy(d_trans, host_machine->transition_table, size_trans, cudaMemcpyHostToDevice);
    cudaMemcpy(d_counts, host_machine->output_counts, size_csr_meta, cudaMemcpyHostToDevice);
    cudaMemcpy(d_indexes, host_machine->output_indexes, size_csr_meta, cudaMemcpyHostToDevice);
    if (size_csr_data > 0) cudaMemcpy(d_list, host_machine->output_list, size_csr_data, cudaMemcpyHostToDevice);
    
    int zero = 0;
    cudaMemcpy(d_alert_count, &zero, sizeof(int), cudaMemcpyHostToDevice);

    // --- E. KERNEL LAUNCH ---
    printf("3. GPU: Launching kernel on %d packets...\n", num_packets);
    int blockSize = 256;
    int gridSize = (num_packets + blockSize - 1) / blockSize;
    
    ac_search_kernel<<<gridSize, blockSize>>>(
        d_packets, d_offsets, d_lengths, num_packets,
        d_trans, d_counts, d_indexes, d_list,
        d_alerts, d_alert_count
    );
    cudaDeviceSynchronize();

    // --- F. RESULT RETRIEVAL ---
    int h_count = 0;
    cudaMemcpy(&h_count, d_alert_count, sizeof(int), cudaMemcpyDeviceToHost);
    
    Alert *h_alerts = (Alert*)malloc(h_count * sizeof(Alert));
    cudaMemcpy(h_alerts, d_alerts, h_count * sizeof(Alert), cudaMemcpyDeviceToHost);

    printf("4. Results (%d alerts):\n", h_count);
    printf("--------------------------------\n");
    for (int i = 0; i < h_count; i++) {
        printf("[GPU ALERT] Packet #%d | Pattern ID %d | Pos %d\n", 
               h_alerts[i].packet_id, h_alerts[i].pattern_id, h_alerts[i].position);
    }

    cudaFree(d_packets); cudaFree(d_trans); cudaFree(d_alerts);
    free(h_all_packets); free(host_machine->transition_table); // etc...

    return 0;
}