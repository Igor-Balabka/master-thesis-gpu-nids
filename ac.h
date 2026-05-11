#ifndef AC_H
#define AC_H

#include <stdio.h>

#define ALPHABET_SIZE 256

// --- Structures ---

/**
 * Temporary node for pattern IDs found at each state.
 * Used only during the construction phase (Phase 1 & 2).
 */
typedef struct OutputNode
{
    int pattern_id;
    struct OutputNode *next;
} OutputNode;

/**
 * AC_Automata: The main Aho-Corasick Deterministic Finite Automaton (DFA).
 * * Performance Note: To be GPU-friendly, we convert the linked lists of patterns
 * into a "Flat" representation (similar to CSR - Compressed Sparse Row).
 * This allows the GPU to access matches without following pointers.
 */
typedef struct
{

    int *transition_table;

    // CSR (Compressed Sparse Row) representation for matches
    int *output_counts;
    int *output_indexes;
    int *output_list;

    int total_outputs; // Total number of pattern occurrences in the machine
    int num_states;    // Current number of states in the DFA
    int capacity;      // Allocated capacity for states

    OutputNode **temp_outputs;
} AC_Automata;

/**
 * ac_create: Allocates and initializes the AC_Automata structure.
 * Sets up the root state and initial memory buffers.
 */
AC_Automata *ac_create();

/**
 * ac_free: cleanup of all host memory buffers.
 */
void ac_free(AC_Automata *m);

/**
 * ac_add_pattern: Phase 1 - Builds the Tree.
 * @param m The automaton pointer.
 * @param pattern The string to detect.
 * @param pattern_id A unique identifier for this rule/keyword.
 */
void ac_add_pattern(AC_Automata *m, const char *pattern, int pattern_id);

/**
 * ac_finalize: Phase 2 - Computes failure links and optimizes transitions.
 * This function converts the Tree into a full DFA and flattens the output lists
 * into a single contiguous memory block for maximum search performance.
 */
void ac_finalize(AC_Automata *m);

/**
 * ac_search_benchmark: Baseline CPU search function.
 * Processes a text buffer of length 'len' and returns the total number of matches.
 */
long ac_search_benchmark(const AC_Automata *m, const char *text, long len);

#endif