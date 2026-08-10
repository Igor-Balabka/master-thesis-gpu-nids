//AC automata
#ifndef AC_H
#define AC_H

#include <stdio.h>
#include "config.h"

typedef struct OutputNode {
    int pattern_id;
    struct OutputNode *next;
} OutputNode;

typedef struct {
    int *transition_table;
    int *output_counts;
    int *output_indexes;
    int *output_list;

    int total_outputs;
    int num_states;
    int capacity;

    OutputNode **temp_outputs;
} AC_Automata;

AC_Automata *ac_create(void);
void ac_free(AC_Automata *m);
void ac_add_pattern(AC_Automata *m, const char *pattern, int pattern_id);
void ac_finalize(AC_Automata *m);
long ac_search_benchmark(const AC_Automata *m, const char *text, long len);
void load_patterns(AC_Automata *m, const char *filename);

#endif // AC_H