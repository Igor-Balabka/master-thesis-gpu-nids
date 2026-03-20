#ifndef AC_H
#define AC_H

#include <stdio.h>


#define ALPHABET_SIZE 256

// --- Structures ---


typedef struct OutputNode {
    int pattern_id;
    struct OutputNode *next;
} OutputNode;

/**
 * AC_Machine: The main Aho-Corasick Deterministic Finite Automaton (DFA).
 * Performance Note: This structure uses a Compressed Sparse Row (CSR) 
 */
typedef struct {

    int *transition_table; 
    
    // CSR (Compressed Sparse Row) representation for matches
    int *output_counts;
    int *output_indexes;
    int *output_list;

    int total_outputs; // Total number of pattern occurrences in the machine
    int num_states;    // Current number of states in the DFA
    int capacity;      // Allocated capacity for states (dynamic resizing)
    
    OutputNode **temp_outputs; 
} AC_Machine;


/**
 * ac_create: Allocates and initializes the AC_Machine structure.
 * Returns a pointer to the root state (State 0).
 */
AC_Machine* ac_create();


void ac_free(AC_Machine *m);

/**
 * ac_add_pattern: Adds a new keyword to the trie.
 * @param m The machine pointer.
 * @param pattern The string to detect.
 * @param pattern_id A unique identifier for this rule.
 */
void ac_add_pattern(AC_Machine *m, const char *pattern, int pattern_id);


// ac_finalize: Converter into a DFA and computes failure links. 
void ac_finalize(AC_Machine *m);


long ac_search_benchmark(const AC_Machine *m, const char *text, long len);

#endif