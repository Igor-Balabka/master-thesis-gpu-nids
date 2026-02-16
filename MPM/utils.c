#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "utils.h"

char* load_file(const char* filename, long* length) {
    FILE* f = fopen(filename, "rb");
    if (!f) { perror("Error reading file"); exit(1); }
    fseek(f, 0, SEEK_END);
    *length = ftell(f);
    fseek(f, 0, SEEK_SET);
    char* buffer = (char*)malloc(*length + 1);
    fread(buffer, 1, *length, f);
    buffer[*length] = '\0';
    fclose(f);
    return buffer;
}

void load_patterns(AC_Machine* ac, const char* filename) {
    FILE* f = fopen(filename, "r");
    if (!f) { perror("Error loading patterns"); exit(1); }
    char line[1024];
    int id = 1;
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\n")] = 0;
        if (strlen(line) > 0) ac_add_pattern(ac, line, id++);
    }
    fclose(f);
}