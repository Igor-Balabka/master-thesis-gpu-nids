#ifndef AC_H
#define AC_H

#include <stdio.h>

#define ALPHABET_SIZE 256

// --- Structures ---

typedef struct OutputNode {
    int pattern_id;
    struct OutputNode *next;
} OutputNode;

typedef struct {
    int *transition_table; 
    
    // CSR (Compressed Sparse Row) for outputs
    int *output_counts;
    int *output_indexes;
    int *output_list;

    int total_outputs;
    int num_states;
    int capacity;    
    
    OutputNode **temp_outputs; 
} AC_Machine;


// Creates a new Aho-Corasick machine
AC_Machine* ac_create();

void ac_free(AC_Machine *m);

// Adds a pattern to the machine
void ac_add_pattern(AC_Machine *m, const char *pattern, int pattern_id);

// Transformation to a DFA
void ac_finalize(AC_Machine *m);

// Benchmarking Function
long ac_search_benchmark(const AC_Machine *m, const char *text, long len);

#endif 