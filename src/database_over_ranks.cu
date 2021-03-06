
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

// CUDA-C includes
#include <cuda.h>
#include <cuda_runtime.h>

#include <cstdio>

#define DEBUG_CUDA 0
#define TESTPERFORMANCE_NO_LEVENSHTEIN 0

#define MIN3(a, b, c) \
    ((a) < (b) ? ((a) < (c) ? (a) : (c)) : ((b) < (c) ? (b) : (c)))

int *d_numbersOfMatch;

__global__ void
searchPattern(char *buf, int n_bytes, char **pattern, int nb_patterns, int lastPatternAnalyzedByGPU, int *sizePatterns,
              int *numbersOfMatch, int indexFinishMyPieceWithoutExtra, int myRank, int numberProcesses,
              int indexStartMyPiece, int approx_factor) {

    int i;
    i = blockIdx.x * blockDim.x + threadIdx.x;

    // I analyze the second half of the patterns
    if (i < lastPatternAnalyzedByGPU) {

        if (TESTPERFORMANCE_NO_LEVENSHTEIN) {
            /*

             I should sleep for 1 microsecond

            The following code works just with Compute Capability >= 7.0
            unsigned int ns = 1000;
            __nanosleep(ns);

            Without the possibility to use nanosleep the only thing that it's possible to do is to wait an arbitrary number of clocks. But we don't know how many clocks correspond to a sleep of 1 microsecond.
            I could try through measurements to understand how many clocks correspond to 1 microsecond, but this is not so reliable. Different GPU can have different velocity (maybe one is running higher clock speed).

            clock_t start_clock = clock();
            clock_t clock_offset = 0;
            while (clock_offset < clock_count)
            {
                clock_offset = clock() - start_clock;
            }
            d_o[0] = clock_offset;

            */

        } else {

#if DEBUG_CUDA
            printf(
                            "MPI %d (out of %d). GPU: Started "
                            "to analize pattern n° %d.\n",
                            myRank, numberProcesses,
                            i);
#endif

            int sizeActualPattern = sizePatterns[i];

            int *column;
            column = (int *) malloc((sizeActualPattern + 1) * sizeof(int));
            if (column == NULL) {
                /*fprintf(
                        stderr,
                        "Error: unable to allocate memory for column (%ldB)\n",
                        (size_pattern + 1) * sizeof(int));
                // return 1;*/
            }

            // If I am not the last rank I should take in consideration
            // extra characters from the next piece: in this way I don't
            // miss words which are placed between two pieces. If am the
            // last rank I don't take extra characters as the other ranks
            // since the file is finished.
            int indexFinishMyPieceWithExtra =
                    indexFinishMyPieceWithoutExtra;
            if (myRank != numberProcesses - 1) {
                indexFinishMyPieceWithExtra += sizeActualPattern - 1;
            }

            // Traverse the input data up to the end of the file
            n_bytes = indexFinishMyPieceWithExtra;

            int r;
            for (r = indexStartMyPiece; r < n_bytes - approx_factor; r++) {

                int distance = 0;
                int size;
                size = sizeActualPattern;
                if (n_bytes - r < sizeActualPattern) {
                    size = n_bytes - r;
                }

                // I cannot call directly levenshtein function in GPU Code

                unsigned int x, y, lastdiag, olddiag;
                char * s1 = pattern[i];
                char *s2 = &buf[r];

#pragma unroll
                for (y = 1; y <= size; y++) {
                    column[y] = y;
                }
#pragma unroll
                for (x = 1; x <= size; x++) {
                    column[0] = x;
                    lastdiag = x - 1;
                    for (y = 1; y <= size; y++) {
                        olddiag = column[y];
                        column[y] = MIN3(column[y] + 1, column[y - 1] + 1,
                                         lastdiag + (s1[y - 1] == s2[x - 1] ? 0 : 1));
                        lastdiag = olddiag;
                    }
                }

                distance = column[size];

                if (distance <= approx_factor) {
                    numbersOfMatch[i] += 1;

                }
            }

            free(column);
        }

    }

}


extern "C" int initializeGPU(char *buf, int n_bytes, char **pattern, int nb_patterns, int lastPatternAnalyzedByGPU,
                             int *sizePatterns, int indexFinishMyPieceWithoutExtra, int myRank, int numberProcesses,
                             int indexStartMyPiece, int approx_factor, int * numberOfMatchesInitialized) {

#if DEBUG_CUDA
    printf("CUDA_DEBUG. Starting allocating data structures and memory transfers...\n");
#endif

    // I need to know the size of patterns to copy the data.
    // So I copy an array containing all the sizes of the patterns.
    int *d_sizePatterns;
    cudaMalloc(&d_sizePatterns, nb_patterns * sizeof(int));
    cudaMemcpy(d_sizePatterns, sizePatterns, nb_patterns * sizeof(int), cudaMemcpyHostToDevice);

    // Allocate space for the buffer and copy data.
    char *d_buf;
    cudaMalloc(&d_buf, n_bytes * sizeof(char));
    cudaMemcpy(d_buf, buf, n_bytes * sizeof(char), cudaMemcpyHostToDevice);

    // Allocate array where to save the number of matches
    cudaMallocHost(&d_numbersOfMatch, nb_patterns * sizeof(int));
    cudaMemcpy(d_numbersOfMatch, numberOfMatchesInitialized, nb_patterns * sizeof(int), cudaMemcpyHostToDevice);

    // Allocate array of patterns: that is an array of arrays.
    // Need to use cudaMallocHost otherwise the following malloc throws a Segmentation Fault
    char **d_pattern;
    cudaMallocHost(&d_pattern, nb_patterns * sizeof(char *));

    // Allocate space for each pattern and copy it
    for (int i = 0; i < nb_patterns; i++) {
        cudaMallocHost(&(d_pattern[i]), sizePatterns[i] * sizeof(char));
        cudaMemcpy(d_pattern[i], pattern[i], sizePatterns[i] * sizeof(char), cudaMemcpyHostToDevice);
    }

    int sizeGrid = 256;
    int sizeBlocks = 10;

#if DEBUG_CUDA
    printf("CUDA_DEBUG. Going to call the kernel code\n");
#endif

    searchPattern<<<sizeGrid, sizeBlocks>>>(d_buf, n_bytes, d_pattern, nb_patterns, lastPatternAnalyzedByGPU,
                                            d_sizePatterns, d_numbersOfMatch, indexFinishMyPieceWithoutExtra, myRank,
                                            numberProcesses, indexStartMyPiece, approx_factor);

#if DEBUG_CUDA
    printf("CUDA_DEBUG. Kernel code returned.\n");
#endif

#if DEBUG_CUDA
    printf("CUDA_DEBUG. Copied results of CUDA.\n");
#endif

    return 1;

}

extern "C" int *
getGPUResult(int nb_patterns) {

    // Allocate local structure where to save the number of matches
    int *numbersOfMatch = (int *) malloc(nb_patterns * sizeof(int));

    // Copy the results from the GPU
    cudaMemcpy(numbersOfMatch, d_numbersOfMatch, nb_patterns * sizeof(int),
               cudaMemcpyDeviceToHost);

    return numbersOfMatch;
}