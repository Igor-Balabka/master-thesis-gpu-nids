#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cuda_runtime.h>

// Helper function for sorting results --> AI
int compareInt(const void * a, const void * b) {
    return ( *(int*)a - *(int*)b );
}

// Host function: Constructs the LPS array
void constructLps(char * pat, int* lps){
    int m = strlen(pat);

    // len stores the length of longest prefix which
    // is also a suffix for the previous index
    int len = 0;

    // lps[0] is always 0
    lps[0] = 0;

    int i = 1;
    while(i < m){
        // If characters match, increment the size of lps
        if (pat[i] == pat[len]){
            len ++;
            lps[i] = len;
            i++;
        }
        // If there is a mismatch
        else{
            if (len != 0){
                // Update len to the previous lps value
                // to avoid reduntant comparisons
                len = lps[len-1];
            }
            else{
                // If no matching prefix found, set lps[i] to 0
                lps[i] = 0;
                i++;
            }
        }
    }
}

// CUDA Kernel: Performs the search in parallel
__global__ void kmpSearchKernel(char* d_txt, int n, char* d_pat, int m, int* d_lps, int* d_found, int* d_count, int chunkSize) {
    // Calculate global thread ID
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    
    // Define the start index for this thread's chunk
    int start_idx = tid * chunkSize;
    
    // Boundary check
    if (start_idx >= n) return;

    // Define the end index. 
    // CRITICAL: We must read past the chunk size by (m - 1) characters
    // to handle patterns that overlap the boundary between two threads.
    int end_idx = start_idx + chunkSize + (m - 1);
    if (end_idx > n) end_idx = n;

    // Pointers i and j, for traversing the text and pattern
    int i = start_idx; 
    int j = 0;

    while(i < end_idx){
        // If characters match, move both pointers forward
        if(d_txt[i] == d_pat[j]){
            i++;
            j++;

            // If the entire pattern is matched
            if(j == m){
                int match_index = i - j;

                // Deduplication Logic:
                // Since threads read overlapping regions, two threads might find the same pattern match.
                // We strictly allow a thread to report a match ONLY if the match starts within its assigned 'chunkSize'.
                if (match_index >= start_idx && match_index < start_idx + chunkSize) {
                    
                    // Atomic addition to safely increment the global counter and get a unique index
                    int pos = atomicAdd(d_count, 1);
                    d_found[pos] = match_index;
                }

                // Use LPS of previous index to skip unnecessary comparisons
                j = d_lps[j-1];
            }
        }
        // If there is a mismatch
        else{
            // Use lps value of previous index to avoid redundant comparisons
            if (j != 0)
                j = d_lps[j - 1];
            else
                i++;
        }
    }
}

// Wrapper function to manage memory and kernel launch
int * searchCUDA(char* pat, char* txt, int *result_count){
    int n = strlen(txt);
    int m = strlen(pat);

    // 1. Prepare LPS on Host
    int* h_lps = (int*)malloc(sizeof(int) * m);
    constructLps(pat, h_lps);

    // 2. Allocate memory on Device (GPU)
    char *d_txt, *d_pat;
    int *d_lps, *d_found, *d_count;
    
    cudaMalloc((void**)&d_txt, n * sizeof(char));
    cudaMalloc((void**)&d_pat, m * sizeof(char));
    cudaMalloc((void**)&d_lps, m * sizeof(int));
    // Worst case size: match at every position
    cudaMalloc((void**)&d_found, n * sizeof(int)); 
    cudaMalloc((void**)&d_count, sizeof(int));

    // 3. Copy data Host -> Device
    cudaMemcpy(d_txt, txt, n * sizeof(char), cudaMemcpyHostToDevice);
    cudaMemcpy(d_pat, pat, m * sizeof(char), cudaMemcpyHostToDevice);
    cudaMemcpy(d_lps, h_lps, m * sizeof(int), cudaMemcpyHostToDevice);
    
    // Initialize count to 0
    int initial_count = 0;
    cudaMemcpy(d_count, &initial_count, sizeof(int), cudaMemcpyHostToDevice);

    // 4. Kernel Configuration
    // We split the text into chunks. 256 chars per thread is an arbitrary choice.
    int minGridSize, blockSize;
    cudaOccupancyMaxPotentialBlockSize(&minGridSize, &blockSize, kmpSearchKernel, 0, 0);

    int chunkSize = 256; 
    int numThreadsNeeded = (n + chunkSize - 1) / chunkSize;
    int blocksPerGrid = (numThreadsNeeded + blockSize - 1) / blockSize;

    if(blocksPerGrid == 0){
        blocksPerGrid = 1;
    }

    // Launch Kernel
    kmpSearchKernel<<<blocksPerGrid, blockSize>>>(d_txt, n, d_pat, m, d_lps, d_found, d_count, chunkSize);
    
    // Check for kernel errors
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess) {
        printf("CUDA Error: %s\n", cudaGetErrorString(err));
    }
    
    // Wait for GPU to finish
    cudaDeviceSynchronize();

    // 5. Retrieve results
    int h_count = 0;
    cudaMemcpy(&h_count, d_count, sizeof(int), cudaMemcpyDeviceToHost);
    *result_count = h_count;

    int *res = NULL;
    if (h_count > 0) {
        res = (int*)malloc(sizeof(int) * h_count);
        cudaMemcpy(res, d_found, h_count * sizeof(int), cudaMemcpyDeviceToHost);
        
        // CUDA threads run in parallel, so results are not ordered. We sort them for clean output.
        qsort(res, h_count, sizeof(int), compareInt);
    }

    // 6. Free memory
    cudaFree(d_txt);
    cudaFree(d_pat);
    cudaFree(d_lps);
    cudaFree(d_found);
    cudaFree(d_count);
    free(h_lps);

    return res;
}

int main() {
    char txt[] = "aabaacaadaabaaba";
    char pat[] = "aaba";

    int count = 0;
    // Call the CUDA wrapper function
    int *res = searchCUDA(pat, txt, &count);

    // Print results
    for (int i = 0; i < count; i++) {
        printf("%d ", res[i]);
    }
    printf("\n");

    if (res != NULL) {
        free(res);
    }

    return 0;
}