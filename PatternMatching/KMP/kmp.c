#include <stdio.h>
#include <stdlib.h>
#include <string.h>


// code from https://www.geeksforgeeks.org/dsa/kmp-algorithm-for-pattern-searching/#kmp-pattern-matching-algorithm just transformed in C
void constructLps(char * pat, int* lps){

    // len stores the length of longest prefix which
    // is also a suffix for the previous index
    int len = 0;

    // lps[0] is always 0
    lps[0] = 0;

    int i = 1;
    while(i < strlen(pat)){

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

int * search(char* pat, char* txt, int *result_count){
    int n = strlen(txt);
    int m = strlen(pat);

    int* lps = (int*)malloc(sizeof(int)*m);

    constructLps(pat,lps);


    //dynamic table
    int capacity = 10;
    int count = 0;
    int *res = (int*)malloc(sizeof(int)*capacity);

    // Pointers i and j, for traversing
    // the text and pattern
    int i = 0;
    int j = 0;

    while(i < n){
        // If characters match, move both pointers forward
        if(txt[i] == pat[j]){
            i ++;
            j ++;


            // If the entire pattern is matched
            // store the start index in result
            if(j==m){

                //if table is full, need to add more space
                if (count >= capacity) {
                    capacity *= 2;
                    res = (int*)realloc(res, sizeof(int) * capacity);
                }
                
                res[count++] = i - j;

                // Use LPS of previous index to
                // skip unnecessary comparisons
                j = lps[j-1];
            }
        }
        // If there is a mismatch
        else{
            // Use lps value of previous index
            // to avoid redundant comparisons
            if (j != 0)
                j = lps[j - 1];
            else
                i++;
            }
        }
    free(lps);
    *result_count = count;
    return res;

}

int main() {
    char txt[] = "aabaacaadaabaaba";
    char pat[] = "aaba";

    int count = 0;
    int *res = search(pat, txt, &count);

    for (int i = 0; i < count; i++) {
        printf("%d ", res[i]);
    }
    printf("\n");

    if (res != NULL) {
        free(res);
    }

    return 0;
}