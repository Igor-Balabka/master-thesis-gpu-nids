#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ac.h"

#define INITIAL_CAPACITY 1000

//------------------------------ Private Section (Internal Helpers) ------------------------------

/**
 * Resizes the internal structures of the Aho-Corasick machine.
 * This is called automatically when the number of states exceeds current capacity.
 * We double the size to maintain an amortized O(1) insertion time.
 */
static void _ac_resize(AC_Machine *m) {
    int old_cap = m->capacity;
    int new_cap = old_cap * 2;
    
    // Resize the transition table (the core DFA matrix)
    m->transition_table = (int*)realloc(m->transition_table, new_cap * ALPHABET_SIZE * sizeof(int));
    // Initialize the new space with -1 (no transition)
    memset(m->transition_table + (old_cap * ALPHABET_SIZE), -1, (new_cap - old_cap) * ALPHABET_SIZE * sizeof(int));

    // Resize metadata arrays
    m->output_counts = (int*)realloc(m->output_counts, new_cap * sizeof(int));
    memset(m->output_counts + old_cap, 0, (new_cap - old_cap) * sizeof(int));

    m->output_indexes = (int*)realloc(m->output_indexes, new_cap * sizeof(int));
    
    // Resize temporary output lists (used only during construction)
    m->temp_outputs = (OutputNode**)realloc(m->temp_outputs, new_cap * sizeof(OutputNode*));
    memset(m->temp_outputs + old_cap, 0, (new_cap - old_cap) * sizeof(OutputNode*));

    m->capacity = new_cap;
}

/**
 * Adds a pattern ID to a specific state in the temporary linked list.
 * Includes a duplication check to ensure we don't count the same rule twice for one state.
 */
static void _add_temp_output(AC_Machine *m, int state, int pattern_id) {
    OutputNode *head = m->temp_outputs[state];
    OutputNode *curr = head;
    
    // Prevent duplicate entries for the same pattern at this state
    while (curr) { 
        if (curr->pattern_id == pattern_id) return; 
        curr = curr->next; 
    }
    
    // Prepend new node to the linked list
    OutputNode *newNode = (OutputNode*)malloc(sizeof(OutputNode));
    newNode->pattern_id = pattern_id;
    newNode->next = head;
    m->temp_outputs[state] = newNode;
}


//------------------------------ Public Section ------------------------------

/**
 * Allocates and initializes a new Aho-Corasick machine.
 */
AC_Machine* ac_create() {
    AC_Machine *m = (AC_Machine*)malloc(sizeof(AC_Machine));
    m->capacity = INITIAL_CAPACITY;
    m->num_states = 1; // State 0 is always the root
    
    m->transition_table = (int*)malloc(m->capacity * ALPHABET_SIZE * sizeof(int));
    memset(m->transition_table, -1, m->capacity * ALPHABET_SIZE * sizeof(int));
    
    m->output_counts = (int*)calloc(m->capacity, sizeof(int));
    m->output_indexes = (int*)malloc(m->capacity * sizeof(int));
    m->output_list = NULL;
    
    m->temp_outputs = (OutputNode**)calloc(m->capacity, sizeof(OutputNode*));
    return m;
}

/**
 * Safely frees all memory associated with the machine,
 * including both the final DFA and temporary construction nodes.
 */
void ac_free(AC_Machine *m) {
    if (m) {
        free(m->transition_table);
        free(m->output_counts);
        free(m->output_indexes);
        if (m->output_list) free(m->output_list);
        if (m->temp_outputs) {
            for (int i = 0; i < m->num_states; i++) {
                OutputNode *curr = m->temp_outputs[i];
                while (curr) { 
                    OutputNode *next = curr->next; 
                    free(curr); 
                    curr = next; 
                }
            }
            free(m->temp_outputs);
        }
        free(m);
    }
}

/**
 * Inserts a pattern into the trie.
 * This is the first phase of the algorithm (Trie construction).
 */
void ac_add_pattern(AC_Machine *m, const char *pattern, int pattern_id) {
    int current_state = 0;
    int len = strlen(pattern);
    
    for (int i = 0; i < len; ++i) {
        unsigned char ch = (unsigned char)pattern[i];
        int idx = current_state * ALPHABET_SIZE + ch;
        
        // If the transition doesn't exist, create a new state
        if (m->transition_table[idx] == -1) {
            if (m->num_states >= m->capacity) {
                _ac_resize(m);
            }
            int new_state = m->num_states++;
            m->transition_table[idx] = new_state;
        }
        current_state = m->transition_table[idx];
    }
    // Mark the final state as an "output" state for this pattern_id
    _add_temp_output(m, current_state, pattern_id);
}

/**
 * Finalizes the automaton by building failure links and converting it into a DFA.
 * Also flattens linked lists into a CSR (Compressed Sparse Row) format for GPU efficiency.
 */
void ac_finalize(AC_Machine *m) {
    int *q = (int*)malloc(m->capacity * sizeof(int));
    int head = 0, tail = 0;
    int *fail = (int*)calloc(m->capacity, sizeof(int)); 

    // Step 1: Initialize BFS queue with states at depth 1
    for (int ch = 0; ch < ALPHABET_SIZE; ++ch) {
        int idx = 0 * ALPHABET_SIZE + ch;
        if (m->transition_table[idx] == -1) {
            m->transition_table[idx] = 0; // Root fallback
        } else {
            int state = m->transition_table[idx];
            fail[state] = 0; 
            q[tail++] = state;
        }
    }
    
    // Step 2: BFS to compute failure links and complete the DFA
    while (head < tail) {
        int state = q[head++];
        
        // Optimization: Merge output patterns from the failure state to the current state
        // (Dictionary suffix property)
        OutputNode *fail_outputs = m->temp_outputs[fail[state]];
        while (fail_outputs) {
            _add_temp_output(m, state, fail_outputs->pattern_id);
            fail_outputs = fail_outputs->next;
        }

        for (int ch = 0; ch < ALPHABET_SIZE; ++ch) {
            int trans_idx = state * ALPHABET_SIZE + ch;
            int next_state = m->transition_table[trans_idx];
            
            if (next_state != -1) {
                // Compute the failure link for the next state
                fail[next_state] = m->transition_table[fail[state] * ALPHABET_SIZE + ch];
                q[tail++] = next_state;
            } else {
                // Flattening the trie into a DFA: missing transitions follow the failure link
                // This makes the search O(1) per character (Direct DFA transition)
                m->transition_table[trans_idx] = m->transition_table[fail[state] * ALPHABET_SIZE + ch];
            }
        }
    }
    free(q); free(fail);

    // Step 3: Convert temporary linked lists to a static CSR (Compressed Sparse Row) format.
    // This is crucial for GPU performance as linked lists are slow in CUDA kernels.
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
    
    // Step 4: Final cleanup of temporary nodes
    for (int i = 0; i < m->num_states; i++) {
        OutputNode *curr = m->temp_outputs[i];
        while (curr) { OutputNode *next = curr->next; free(curr); curr = next; }
    }
    free(m->temp_outputs);
    m->temp_outputs = NULL; 
}

/**
 * Standard CPU search function used for benchmarking and validation.
 * Uses the completed DFA to achieve O(n) complexity.
 */
long ac_search_benchmark(const AC_Machine *m, const char *text, long len) {
    int current_state = 0;
    long total_matches = 0;
    
    for (long i = 0; i < len; ++i) {
        unsigned char ch = (unsigned char)text[i];
        
        // Single transition thanks to the DFA optimization in ac_finalize
        current_state = m->transition_table[current_state * ALPHABET_SIZE + ch];
        
        // Directly increment matches if the current state is an output state
        if (m->output_counts[current_state] > 0) {
            total_matches += m->output_counts[current_state];
        }
    }
    return total_matches;
}