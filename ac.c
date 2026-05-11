#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ac.h"

#define INITIAL_CAPACITY 1000

//------------------------------ Private Section (Internal Helpers) ------------------------------

/**
 * Doubles the capacity of the state machine arrays when they are full.
 */
static void _ac_resize(AC_Automata *m)
{
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

/**
 * Adds a pattern ID to a specific state during construction.
 * Avoids duplicates using a simple linked list check.
 */
static void _add_temp_output(AC_Automata *m, int state, int pattern_id)
{
    OutputNode *head = m->temp_outputs[state];
    OutputNode *curr = head;

    while (curr)
    {
        if (curr->pattern_id == pattern_id)
            return;
        curr = curr->next;
    }

    OutputNode *newNode = (OutputNode *)malloc(sizeof(OutputNode));
    newNode->pattern_id = pattern_id;
    newNode->next = head;
    m->temp_outputs[state] = newNode;
}

/**
 * Initializes the AC Automaton structure.
 */
AC_Automata *ac_create()
{
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

/**
 * Free of the automaton and all internal linked lists.
 */
void ac_free(AC_Automata *m)
{
    if (m)
    {
        free(m->transition_table);
        free(m->output_counts);
        free(m->output_indexes);
        if (m->output_list)
            free(m->output_list);
        if (m->temp_outputs)
        {
            for (int i = 0; i < m->num_states; i++)
            {
                OutputNode *curr = m->temp_outputs[i];
                while (curr)
                {
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

/**
 * Phase 1: Build the tree
 * Inserts the pattern character by character and creates new states as needed.
 */
void ac_add_pattern(AC_Automata *m, const char *pattern, int pattern_id)
{
    int current_state = 0;
    int len = strlen(pattern);

    for (int i = 0; i < len; ++i)
    {
        unsigned char ch = (unsigned char)pattern[i];
        int idx = current_state * ALPHABET_SIZE + ch;

        if (m->transition_table[idx] == -1)
        {
            if (m->num_states >= m->capacity)
            {
                _ac_resize(m);
            }
            int new_state = m->num_states++;
            m->transition_table[idx] = new_state;
        }
        current_state = m->transition_table[idx];
    }
    _add_temp_output(m, current_state, pattern_id);
}

/**
 * Phase 2: Compute Failure Links and build the final DFA.
 * Uses BFS to connect states and optimize transitions
 * to avoid jumping back to the root during search.
 */
void ac_finalize(AC_Automata *m)
{
    int *q = (int *)malloc(m->capacity * sizeof(int));
    int head = 0, tail = 0;
    int *fail = (int *)calloc(m->capacity, sizeof(int));

    for (int ch = 0; ch < ALPHABET_SIZE; ++ch)
    {
        int idx = 0 * ALPHABET_SIZE + ch;
        if (m->transition_table[idx] == -1)
        {
            m->transition_table[idx] = 0;
        }
        else
        {
            int state = m->transition_table[idx];
            fail[state] = 0;
            q[tail++] = state;
        }
    }

    while (head < tail)
    {
        int state = q[head++];

        OutputNode *fail_outputs = m->temp_outputs[fail[state]];
        while (fail_outputs)
        {
            _add_temp_output(m, state, fail_outputs->pattern_id);
            fail_outputs = fail_outputs->next;
        }

        for (int ch = 0; ch < ALPHABET_SIZE; ++ch)
        {
            int trans_idx = state * ALPHABET_SIZE + ch;
            int next_state = m->transition_table[trans_idx];

            if (next_state != -1)
            {
                fail[next_state] = m->transition_table[fail[state] * ALPHABET_SIZE + ch];
                q[tail++] = next_state;
            }
            else
            {

                m->transition_table[trans_idx] = m->transition_table[fail[state] * ALPHABET_SIZE + ch];
            }
        }
    }
    free(q);
    free(fail);

    int total_outputs = 0;
    for (int i = 0; i < m->num_states; i++)
    {
        int count = 0;
        OutputNode *curr = m->temp_outputs[i];
        while (curr)
        {
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
    for (int i = 0; i < m->num_states; i++)
    {
        m->output_indexes[i] = current_idx;
        OutputNode *curr = m->temp_outputs[i];
        while (curr)
        {
            m->output_list[current_idx++] = curr->pattern_id;
            curr = curr->next;
        }
    }

    for (int i = 0; i < m->num_states; i++)
    {
        OutputNode *curr = m->temp_outputs[i];
        while (curr)
        {
            OutputNode *next = curr->next;
            free(curr);
            curr = next;
        }
    }
    free(m->temp_outputs);
    m->temp_outputs = NULL;
}

/**
 * CPU Search Function.
 * Scans a text buffer and returns the total number of pattern matches.
 * Uses the optimized DFA transition table.
 */
long ac_search_benchmark(const AC_Automata *m, const char *text, long len)
{
    int current_state = 0;
    long total_matches = 0;

    for (long i = 0; i < len; ++i)
    {
        unsigned char ch = (unsigned char)text[i];

        current_state = m->transition_table[current_state * ALPHABET_SIZE + ch];

        if (m->output_counts[current_state] > 0)
        {
            total_matches += m->output_counts[current_state];
        }
    }
    return total_matches;
}