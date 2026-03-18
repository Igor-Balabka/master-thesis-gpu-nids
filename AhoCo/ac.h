#ifndef AC_H
#define AC_H

#include <stdio.h>

/**
 * Standard ASCII alphabet size (0-255).
 * Using a full 256-way branching ensures O(1) transitions at the cost of memory.
 */
#define ALPHABET_SIZE 256

// --- Structures ---

/**
 * OutputNode: A temporary linked list node used during the trie construction.
 * Stores pattern IDs that terminate at a specific state.
 * These are flattened into a CSR format during the ac_finalize() phase.
 */
typedef struct OutputNode {
    int pattern_id;
    struct OutputNode *next;
} OutputNode;

/**
 * AC_Machine: The main Aho-Corasick Deterministic Finite Automaton (DFA).
 * * Performance Note: This structure uses a Compressed Sparse Row (CSR) 
 * representation for pattern matches to optimize GPU memory access patterns.
 */
typedef struct {
    /** * Transition Table: A flattened 2D matrix [num_states][ALPHABET_SIZE].
     * Represents the DFA transitions. O(1) lookup: state = table[current_state * 256 + char].
     */
    int *transition_table; 
    
    /* --- CSR (Compressed Sparse Row) representation for matches --- */
    /** Number of patterns found at each state. */
    int *output_counts;
    /** Starting index in 'output_list' for each state's matches. */
    int *output_indexes;
    /** Flattened array of all pattern IDs matched by the automaton. */
    int *output_list;

    int total_outputs; // Total number of pattern occurrences in the machine
    int num_states;    // Current number of states in the DFA
    int capacity;      // Allocated capacity for states (dynamic resizing)
    
    /** * Temporary linked lists used during construction. 
     * NULL after ac_finalize() is called.
     */
    OutputNode **temp_outputs; 
} AC_Machine;


/**
 * ac_create: Allocates and initializes the AC_Machine structure.
 * Returns a pointer to the root state (State 0).
 */
AC_Machine* ac_create();

/**
 * ac_free: Safely deallocates all internal arrays and the machine itself.
 */
void ac_free(AC_Machine *m);

/**
 * ac_add_pattern: Adds a new keyword to the trie.
 * @param m The machine pointer.
 * @param pattern The string to detect.
 * @param pattern_id A unique identifier for this rule.
 */
void ac_add_pattern(AC_Machine *m, const char *pattern, int pattern_id);

/**
 * ac_finalize: Computes failure links and converts the trie into a DFA.
 * It also optimizes the output storage into the CSR format for fast GPU/CPU retrieval.
 * Must be called once all patterns are added and before searching.
 */
void ac_finalize(AC_Machine *m);

/**
 * ac_search_benchmark: A high-speed CPU-based search function.
 * Used as a reference for performance benchmarking and GPU result validation.
 * @param text The payload buffer to scan.
 * @param len The length of the payload.
 * @return Total number of matches found.
 */
long ac_search_benchmark(const AC_Machine *m, const char *text, long len);

#endif