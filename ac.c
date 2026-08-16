#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ac.h"

#define INITIAL_CAPACITY 1000

// Resize the automaton arrays when capacity is reached
static void _ac_resize(AC_Automata *m) {
    int old_cap = m->capacity;
    int new_cap = old_cap * 2;

    m->transition_table = (int *)realloc(m->transition_table, new_cap * ALPHABET_SIZE * sizeof(int));
    memset(m->transition_table + (old_cap * ALPHABET_SIZE), -1, (new_cap - old_cap) * ALPHABET_SIZE * sizeof(int));

    m->output_counts = (int *)realloc(m->output_counts, new_cap * sizeof(int));
    memset(m->output_counts + old_cap, 0, (new_cap - old_cap) * sizeof(int));

    m->output_indexes = (int *)realloc(m->output_indexes, new_cap * sizeof(int));

    m->temp_outputs = (OutputNode **)realloc(m->temp_outputs, new_cap * sizeof(OutputNode *));
    memset(m->temp_outputs + old_cap, 0, (new_cap - old_cap) * sizeof(OutputNode *));

    m->capacity = new_cap;
}

// Add a temporary output pattern to a state
static void _add_temp_output(AC_Automata *m, int state, int pattern_id) {
    OutputNode *head = m->temp_outputs[state];
    OutputNode *curr = head;

    while (curr) {
        if (curr->pattern_id == pattern_id) return;
        curr = curr->next;
    }

    OutputNode *newNode = (OutputNode *)malloc(sizeof(OutputNode));
    newNode->pattern_id = pattern_id;
    newNode->next = head;
    m->temp_outputs[state] = newNode;
}

// Initialize the Aho-Corasick automaton
AC_Automata *ac_create(void) {
    AC_Automata *m = (AC_Automata *)malloc(sizeof(AC_Automata));
    m->capacity = INITIAL_CAPACITY;
    m->num_states = 1;

    m->transition_table = (int *)malloc(m->capacity * ALPHABET_SIZE * sizeof(int));
    memset(m->transition_table, -1, m->capacity * ALPHABET_SIZE * sizeof(int));

    m->output_counts = (int *)calloc(m->capacity, sizeof(int));
    m->output_indexes = (int *)malloc(m->capacity * sizeof(int));
    m->output_list = NULL;

    m->temp_outputs = (OutputNode **)calloc(m->capacity, sizeof(OutputNode *));
    return m;
}

// Free all memory allocated for the automaton
void ac_free(AC_Automata *m) {
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

// Add a single pattern to the trie
void ac_add_pattern(AC_Automata *m, const char *pattern, int pattern_id) {
    int current_state = 0;
    int len = strlen(pattern);

    for (int i = 0; i < len; ++i) {
        unsigned char ch = (unsigned char)pattern[i];
        int idx = current_state * ALPHABET_SIZE + ch;

        if (m->transition_table[idx] == -1) {
            if (m->num_states >= m->capacity) {
                _ac_resize(m);
            }
            int new_state = m->num_states++;
            m->transition_table[idx] = new_state;
        }
        current_state = m->transition_table[idx];
    }
    _add_temp_output(m, current_state, pattern_id);
}

// Build failure links using BFS (Aho-Corasick finalize step)
void ac_finalize(AC_Automata *m) {
    int *q = (int *)malloc(m->capacity * sizeof(int));
    int head = 0, tail = 0;
    int *fail = (int *)calloc(m->capacity, sizeof(int));

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
    free(q);
    free(fail);

    // Convert linked lists to flat arrays for better cache performance
    int total_outputs = 0;
    for (int i = 0; i < m->num_states; i++) {
        int count = 0;
        OutputNode *curr = m->temp_outputs[i];
        while (curr) {
            count++;
            curr = curr->next;
        }
        m->output_counts[i] = count;
        total_outputs += count;
    }
    m->total_outputs = total_outputs;

    if (total_outputs > 0)
        m->output_list = (int *)malloc(total_outputs * sizeof(int));

    int current_idx = 0;
    for (int i = 0; i < m->num_states; i++) {
        m->output_indexes[i] = current_idx;
        OutputNode *curr = m->temp_outputs[i];
        while (curr) {
            m->output_list[current_idx++] = curr->pattern_id;
            curr = curr->next;
        }
    }

    // Free temporary outputs
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

    // Calculate total RAM usage
    size_t trans_size = (size_t)m->capacity * ALPHABET_SIZE * sizeof(int);
    size_t counts_size = (size_t)m->capacity * sizeof(int);
    size_t indexes_size = (size_t)m->capacity * sizeof(int);
    size_t list_size = (size_t)m->total_outputs * sizeof(int);
    
    size_t total_ram_bytes = trans_size + counts_size + indexes_size + list_size + sizeof(AC_Automata);
    double cpu_ram_mb = (double)total_ram_bytes / (1024.0 * 1024.0);

    printf("[CPU DFA Stats] States: %d | Total RAM: %.2f MB\n", m->num_states, cpu_ram_mb);
}

// Search text for patterns
long ac_search_benchmark(const AC_Automata *m, const char *text, long len) {
    int current_state = 0;
    long total_matches = 0;

    for (long i = 0; i < len; ++i) {
        unsigned char ch = (unsigned char)text[i];
        current_state = m->transition_table[current_state * ALPHABET_SIZE + ch];
        if (m->output_counts[current_state] > 0) {
            total_matches += m->output_counts[current_state];
        }
    }
    return total_matches;
}

// Load patterns from a file line by line
void load_patterns(AC_Automata *m, const char *filename) {
    FILE *file = fopen(filename, "r");
    if (!file) {
        fprintf(stderr, " Error: Could not open rules file %s\n", filename);
        exit(1);
    }
    char line[1024];
    int id = 1;
    while (fgets(line, sizeof(line), file)) {
        line[strcspn(line, "\r\n")] = 0;
        if (strlen(line) > 0) {
            ac_add_pattern(m, line, id++);
        }
    }
    fclose(file);
    printf("[Setup] %d patterns loaded from %s\n", id - 1, filename);
}