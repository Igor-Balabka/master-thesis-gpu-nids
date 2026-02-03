#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ALPHABET_SIZE 256


// -- 1. Structure --

// Temporary linked list for the number of rules per state during construction
typedef struct OutputNode {
    int pattern_id;
    struct OutputNode *next;
} OutputNode;


typedef struct {

    int *transition_table; // DFA (Dense)
    
    // Compressed Sparse Row (CSR) for outputs
    int *output_counts;  // Number of rules matched by state X
    int *output_indexes; // Start index in output_list for state X
    int *output_list;    // Flat array containing all rule IDs

    int total_outputs;

    int num_states;
    int max_states;
    
    OutputNode **temp_outputs; // Temporary storage for construction
} AC_Machine;


// -- 2. Memory --

AC_Machine* ac_create(int max_states) {
    AC_Machine *m = (AC_Machine*)malloc(sizeof(AC_Machine));
    m->max_states = max_states;
    m->num_states = 1;
    
    // Allocate transition table and init to -1 (empty)
    m->transition_table = (int*)malloc(max_states * ALPHABET_SIZE * sizeof(int));
    memset(m->transition_table, -1, max_states * ALPHABET_SIZE * sizeof(int));
    
    // Allocate CSR arrays
    m->output_counts = (int*)calloc(max_states, sizeof(int));
    m->output_indexes = (int*)malloc(max_states * sizeof(int));
    m->output_list = NULL; // Will be allocated in finalize
    
    // Allocate temporary linked list array
    m->temp_outputs = (OutputNode**)calloc(max_states, sizeof(OutputNode*));
    
    return m;
}

void ac_free(AC_Machine *m) {
    if (m) {
        if (m->transition_table) free(m->transition_table);
        if (m->output_counts) free(m->output_counts);
        if (m->output_indexes) free(m->output_indexes);
        if (m->output_list) free(m->output_list);
        
        // Free temporary lists if they still exist
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

void _add_temp_output(AC_Machine *m, int state, int pattern_id) {
    OutputNode *head = m->temp_outputs[state];
    
    // Check for duplicates
    OutputNode *curr = head;
    while (curr) {
        if (curr->pattern_id == pattern_id) return;
        curr = curr->next;
    }
    
    // Add to head of list
    OutputNode *newNode = (OutputNode*)malloc(sizeof(OutputNode));
    newNode->pattern_id = pattern_id;
    newNode->next = head;
    m->temp_outputs[state] = newNode;
}

// --- 3. Build ---

void ac_add_pattern(AC_Machine *m, const char *pattern, int pattern_id) {
    int current_state = 0;
    int len = strlen(pattern);
    
    for (int i = 0; i < len; ++i) {
        unsigned char ch = (unsigned char)pattern[i];
        int idx = current_state * ALPHABET_SIZE + ch;
        
        if (m->transition_table[idx] == -1) {
            if (m->num_states >= m->max_states) {
                fprintf(stderr, "Error: Max states reached!\n");
                return;
            }
            int new_state = m->num_states++;
            
            // Initialize new state row to -1
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

    // Initialize depth 1
    for (int ch = 0; ch < ALPHABET_SIZE; ++ch) {
        int idx = 0 * ALPHABET_SIZE + ch;
        if (m->transition_table[idx] == -1) {
            m->transition_table[idx] = 0; 
        } else {
            int state = m->transition_table[idx];
            fail[state] = 0; 
            q[tail++] = state;
        }
    }
    
    // BFS
    while (head < tail) {
        int state = q[head++];
        
        // Propagate outputs from failure state
        OutputNode *fail_outputs = m->temp_outputs[fail[state]];
        while (fail_outputs) {
            _add_temp_output(m, state, fail_outputs->pattern_id);
            fail_outputs = fail_outputs->next;
        }

        // Compute transitions and failure links
        for (int ch = 0; ch < ALPHABET_SIZE; ++ch) {
            int trans_idx = state * ALPHABET_SIZE + ch;
            int next_state = m->transition_table[trans_idx];
            
            if (next_state != -1) {
                // Transition exists -> Calculate failure link
                fail[next_state] = m->transition_table[fail[state] * ALPHABET_SIZE + ch];
                q[tail++] = next_state;
            } else {
                // Transition missing -> Optimize (DFA Dense)
                m->transition_table[trans_idx] = m->transition_table[fail[state] * ALPHABET_SIZE + ch];
            }
        }
    }
    
    free(q);
    free(fail);

    // Convert Temp Lists to CSR Format
    int total_outputs = 0;
    for (int i = 0; i < m->num_states; i++) {
        int count = 0;
        OutputNode *curr = m->temp_outputs[i];
        while (curr) { count++; curr = curr->next; }
        
        m->output_counts[i] = count;
        total_outputs += count;
    }
    m->total_outputs = total_outputs;
    
    if (total_outputs > 0) {
        m->output_list = (int*)malloc(total_outputs * sizeof(int));
    }
    
    int current_idx = 0;
    for (int i = 0; i < m->num_states; i++) {
        m->output_indexes[i] = current_idx;
        
        OutputNode *curr = m->temp_outputs[i];
        while (curr) {
            m->output_list[current_idx++] = curr->pattern_id;
            curr = curr->next;
        }
    }
    
    // Cleanup temp lists
    for (int i = 0; i < m->num_states; i++) {
        OutputNode *curr = m->temp_outputs[i];
        while (curr) {
            OutputNode *next = curr->next;
            free(curr);
            curr = next;
        }
    }
    free(m->temp_outputs);
    m->temp_outputs = NULL; 
}

// --- 4. RUNTIME ---

void ac_search(const AC_Machine *m, const char *text) {
    int current_state = 0;
    int len = strlen(text);
    
    printf("\n--- Packets analysis (%d bytes) ---\n", len);
    
    for (int i = 0; i < len; ++i) {
        unsigned char ch = (unsigned char)text[i];
        
        // DFA Transition (O(1))
        current_state = m->transition_table[current_state * ALPHABET_SIZE + ch];
        
        // Check for alerts
        int count = m->output_counts[current_state];
        if (count > 0) {
            int start_idx = m->output_indexes[current_state];
            
            for (int k = 0; k < count; k++) {
                int pattern_id = m->output_list[start_idx + k];
                printf("[ALERT] Pattern ID %d found at position %d\n", pattern_id, i);
            }
        }
    }
}

// --- 5. MAIN ---

int main() {
    AC_Machine *nids = ac_create(1000);
    
    ac_add_pattern(nids, "he", 101);
    ac_add_pattern(nids, "she", 500);
    ac_add_pattern(nids, "his", 999);
    ac_add_pattern(nids, "hers", 42); 
    
    printf("Building the automaton...\n");
    ac_finalize(nids);
    printf("Automaton built. States used: %d, Total Outputs stored: %d\n", 
           nids->num_states, nids->total_outputs);
    

    const char *payload = "ahishers"; 
    
    ac_search(nids, payload);
    
    ac_free(nids);
    
    return 0;
}