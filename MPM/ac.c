#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ac.h"

#define INITIAL_CAPACITY 1000

// Internal: Resize the automaton tables when capacity is reached
static void _ac_resize(AC_Machine *m) {
    int old_cap = m->capacity;
    int new_cap = old_cap * 2;
    
    m->transition_table = (int*)realloc(m->transition_table, new_cap * ALPHABET_SIZE * sizeof(int));
    memset(m->transition_table + (old_cap * ALPHABET_SIZE), -1, (new_cap - old_cap) * ALPHABET_SIZE * sizeof(int));

    m->output_counts = (int*)realloc(m->output_counts, new_cap * sizeof(int));
    memset(m->output_counts + old_cap, 0, (new_cap - old_cap) * sizeof(int));

    m->output_indexes = (int*)realloc(m->output_indexes, new_cap * sizeof(int));
    
    m->temp_outputs = (OutputNode**)realloc(m->temp_outputs, new_cap * sizeof(OutputNode*));
    memset(m->temp_outputs + old_cap, 0, (new_cap - old_cap) * sizeof(OutputNode*));

    m->capacity = new_cap;
}

// Internal: Add a pattern ID to a specific state (handles duplicates)
static void _add_temp_output(AC_Machine *m, int state, int pattern_id) {
    OutputNode *head = m->temp_outputs[state];
    OutputNode *curr = head;
    while (curr) { 
        if (curr->pattern_id == pattern_id) return; 
        curr = curr->next; 
    }
    OutputNode *newNode = (OutputNode*)malloc(sizeof(OutputNode));
    newNode->pattern_id = pattern_id;
    newNode->next = head;
    m->temp_outputs[state] = newNode;
}

AC_Machine* ac_create() {
    AC_Machine *m = (AC_Machine*)malloc(sizeof(AC_Machine));
    m->capacity = INITIAL_CAPACITY;
    m->num_states = 1;
    m->transition_table = (int*)malloc(m->capacity * ALPHABET_SIZE * sizeof(int));
    memset(m->transition_table, -1, m->capacity * ALPHABET_SIZE * sizeof(int));
    m->output_counts = (int*)calloc(m->capacity, sizeof(int));
    m->output_indexes = (int*)malloc(m->capacity * sizeof(int));
    m->output_list = NULL;
    m->temp_outputs = (OutputNode**)calloc(m->capacity, sizeof(OutputNode*));
    return m;
}

void ac_free(AC_Machine *m) {
    if (!m) return;
    free(m->transition_table);
    free(m->output_counts);
    free(m->output_indexes);
    if (m->output_list) free(m->output_list);
    if (m->temp_outputs) {
        for (int i = 0; i < m->num_states; i++) {
            OutputNode *curr = m->temp_outputs[i];
            while (curr) { OutputNode *next = curr->next; free(curr); curr = next; }
        }
        free(m->temp_outputs);
    }
    free(m);
}

void ac_add_pattern(AC_Machine *m, const char *pattern, int pattern_id) {
    int current_state = 0;
    int len = strlen(pattern);
    for (int i = 0; i < len; ++i) {
        unsigned char ch = (unsigned char)pattern[i];
        int idx = current_state * ALPHABET_SIZE + ch;
        if (m->transition_table[idx] == -1) {
            if (m->num_states >= m->capacity) _ac_resize(m);
            int new_state = m->num_states++;
            m->transition_table[idx] = new_state;
        }
        current_state = m->transition_table[idx];
    }
    _add_temp_output(m, current_state, pattern_id);
}

void ac_finalize(AC_Machine *m) {
    int *q = (int*)malloc(m->capacity * sizeof(int));
    int head = 0, tail = 0;
    int *fail = (int*)calloc(m->capacity, sizeof(int)); 

    // Build failure links using BFS
    for (int ch = 0; ch < ALPHABET_SIZE; ++ch) {
        int idx = 0 * ALPHABET_SIZE + ch;
        if (m->transition_table[idx] == -1) m->transition_table[idx] = 0; 
        else q[tail++] = m->transition_table[idx];
    }
    
    while (head < tail) {
        int state = q[head++];
        // Merge outputs from failure state
        OutputNode *fail_outputs = m->temp_outputs[fail[state]];
        while (fail_outputs) {
            _add_temp_output(m, state, fail_outputs->pattern_id);
            fail_outputs = fail_outputs->next;
        }
        for (int ch = 0; ch < ALPHABET_SIZE; ++ch) {
            int trans_idx = state * ALPHABET_SIZE + ch;
            if (m->transition_table[trans_idx] != -1) {
                fail[m->transition_table[trans_idx]] = m->transition_table[fail[state] * ALPHABET_SIZE + ch];
                q[tail++] = m->transition_table[trans_idx];
            } else {
                m->transition_table[trans_idx] = m->transition_table[fail[state] * ALPHABET_SIZE + ch];
            }
        }
    }
    free(q); free(fail);

    // Convert temp lists to CSR format for fast access
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
        int current_idx = 0;
        for (int i = 0; i < m->num_states; i++) {
            m->output_indexes[i] = current_idx;
            OutputNode *curr = m->temp_outputs[i];
            while (curr) {
                m->output_list[current_idx++] = curr->pattern_id;
                curr = curr->next;
            }
        }
    }
}

long ac_search_benchmark(const AC_Machine *m, const char *text, long len) {
    int current_state = 0;
    long total_matches = 0;
    for (long i = 0; i < len; ++i) {
        current_state = m->transition_table[current_state * ALPHABET_SIZE + (unsigned char)text[i]];
        if (m->output_counts[current_state] > 0) {
            total_matches += m->output_counts[current_state];
        }
    }
    return total_matches;
}