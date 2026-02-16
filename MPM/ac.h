#ifndef AC_H
#define AC_H

#include <stdio.h>

#define ALPHABET_SIZE 256

// Temporary node for pattern IDs during construction
typedef struct OutputNode {
    int pattern_id;
    struct OutputNode *next;
} OutputNode;

// The Aho-Corasick Machine structure
typedef struct {
    int *transition_table;  // Flattened 2D array [num_states * ALPHABET_SIZE]
    
    // CSR (Compressed Sparse Row) for pattern outputs
    int *output_counts;     // Number of patterns matching at this state
    int *output_indexes;    // Start index in output_list for this state
    int *output_list;       // Flat list of all matching pattern IDs

    int total_outputs;
    int num_states;
    int capacity;    
    
    OutputNode **temp_outputs; // Only used during construction
} AC_Machine;

// Function declarations
AC_Machine* ac_create();
void ac_free(AC_Machine *m);
void ac_add_pattern(AC_Machine *m, const char *pattern, int pattern_id);
void ac_finalize(AC_Machine *m);
long ac_search_benchmark(const AC_Machine *m, const char *text, long len);

#endif