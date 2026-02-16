#include <stdio.h>
#include <assert.h>
#include <string.h>
#include "ac.h"

void test_logic() {
    AC_Machine *m = ac_create();
    ac_add_pattern(m, "apple", 1);
    ac_add_pattern(m, "app", 2);
    ac_finalize(m);

    // "apple" matches both "apple" and "app"
    long matches = ac_search_benchmark(m, "apple", 5);
    assert(matches == 2);
    
    ac_free(m);
    printf("Unit Test: Logic check PASSED\n");
}

int main() {
    test_logic();
    return 0;
}