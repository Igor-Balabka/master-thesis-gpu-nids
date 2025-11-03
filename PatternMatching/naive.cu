#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>


//https://developer.nvidia.com/blog/easy-introduction-cuda-c-and-c/

// Hello World Part
__global__ void helloKernel()
{

    if (threadIdx.x == 0 && blockIdx.x == 0)
    {
        printf("Hello World depuis le GPU !\n");
    }
}
extern "C" void runHelloOnGPU()
{

    helloKernel<<<1, 1>>>();
    cudaDeviceSynchronize();
}


__global__ void naivePatternMatching_kernel(int sizeText, int sizePattern, const char *d_text, const char *d_pattern, int *d_matchResults){
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i <= sizeText - sizePattern){
        bool patternFound = true;
        for (int j = 0; j < sizePattern; j++)
        {
            if (d_text[i + j] != d_pattern[j])
            {
                patternFound = false;
                break;
            }
        }
        if (patternFound)
        {
            d_matchResults[i] = 1;
        }
        else
        {
            d_matchResults[i] = 0;
        }
    }
}


extern "C" int naivePatternMatching(int sizeText, int sizePattern, char * text, char * pattern ){

    char *d_text, *d_pattern;
    int *d_matchResults;

    cudaMalloc(&d_text, sizeText * sizeof(char));
    cudaMalloc(&d_pattern, sizePattern * sizeof(char));
    cudaMalloc(&d_matchResults, sizeText * sizeof(int));

    cudaMemcpy(d_text,text,sizeText* sizeof(char), cudaMemcpyHostToDevice);
    cudaMemcpy(d_pattern,pattern, sizePattern * sizeof(char), cudaMemcpyHostToDevice);

    int numThreads = sizeText - sizePattern +1;
    int threadsPerBlock = 256;
    int numBlocks = (numThreads + threadsPerBlock -1)/ threadsPerBlock;

    naivePatternMatching_kernel<<<numBlocks,threadsPerBlock>>>(sizeText,sizePattern,d_text,d_pattern,d_matchResults);

    int *h_matchResults = (int *)malloc(sizeText * sizeof(int));

    cudaMemcpy(h_matchResults,d_matchResults,sizeText*sizeof(int),cudaMemcpyDeviceToHost);


    int totalPatternFound = 0;
    for (int i = 0; i < sizeText; i++)
    {
        if(h_matchResults[i] ==1){
            printf("pattern found at index %d \n",i);
            totalPatternFound ++;
        }
    }
    cudaFree(d_text);
    cudaFree(d_pattern);
    cudaFree(d_matchResults);
    free(h_matchResults);

    return totalPatternFound;
}




