#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ac.h"
#include "utils.h"
#include <cuda_runtime.h>

// Loads the entire file content into memory
char* load_file(const char* filename, long* length) {
    FILE* f = fopen(filename, "rb");
    if (!f) { perror("Error opening data file"); exit(1); }
    
    fseek(f, 0, SEEK_END);
    *length = ftell(f);
    fseek(f, 0, SEEK_SET);
    
    char* buffer = NULL;
    // cudaHostAlloc allows for faster PCIe transfers (GPU) 
    // and standard pointer access (CPU).
    cudaError_t err = cudaHostAlloc((void**)&buffer, *length + 1, cudaHostAllocDefault);
    if (err != cudaSuccess) {
        fprintf(stderr, "Fatal: cudaHostAlloc failed. Is a GPU driver installed?\n");
        exit(1);
    }
    
    if (fread(buffer, 1, *length, f) != (size_t)*length) {
        fprintf(stderr, "Error: Could not read file content.\n");
        cudaFreeHost(buffer);
        exit(1);
    }
    
    buffer[*length] = '\0';
    fclose(f);
    return buffer;
}

// Reads a rules file and adds patterns to the automaton
void load_patterns(AC_Machine* ac, const char* filename) {
    FILE* f = fopen(filename, "r");
    if (!f) { perror("Error reading patterns file"); exit(1); }
    
    char line[1024];
    int id = 1;
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\n")] = 0;
        if (strlen(line) > 0) {
            ac_add_pattern(ac, line, id++);
        }
    }
    fclose(f);
    printf("Patterns loaded: %d\n", id - 1);
}