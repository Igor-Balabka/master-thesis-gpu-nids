// AC automata header file
#ifndef AC_H
#define AC_H

#include <stdio.h>
#include "config.h"

// Linked list node to temporarily store matched pattern IDs for each state
typedef struct OutputNode {
    int pattern_id;
    struct OutputNode *next;
} OutputNode;

// Main structure for the Aho-Corasick automaton
typedef struct {
    int *transition_table; // Flat 2D array: states x alphabet size
    int *output_counts;    // Number of matches per state
    int *output_indexes;   // Starting index in the output list
    int *output_list;      // Flat list of all pattern IDs

    int total_outputs;     // Total number of outputs across all states
    int num_states;        // Current total number of states in the automaton
    int capacity;          // Max allocated capacity before resizing

    OutputNode **temp_outputs; // Temporary linked lists used only during construction
} AC_Automata;

// Create and initialize a new automaton
AC_Automata *ac_create(void);

// Free all memory used by the automaton
void ac_free(AC_Automata *m);

// Add a single pattern string to the automaton's trie
void ac_add_pattern(AC_Automata *m, const char *pattern, int pattern_id);

// Finalize the automaton by building failure links and flattening tables
void ac_finalize(AC_Automata *m);

// Search for patterns inside a text block and return the match count
long ac_search_benchmark(const AC_Automata *m, const char *text, long len);

// Load rules/patterns from a text file line by line
void load_patterns(AC_Automata *m, const char *filename);

#endif // AC_H