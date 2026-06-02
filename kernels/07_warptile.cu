#include "../include/common.h"


__global__ void warptile_kernel(int M, int N, int K,
                             float alpha,
                             const float* A,
                             const float* B,
                             float beta,
                             float* C)
{
    constexpr int BM=128;
    constexpr int BK =8;
    constexpr int BN = 128;
    constexpr int WM = 64;
    constexpr int WN = 64;
    constexpr int TM = 8;
    constexpr int TN = 4;
    __shared__ float As[BM][BK];
    __shared__ float Bs[BK][BN];
    
    





}

void launch_warptile_kernel(int M, int N, int K,
                         float alpha,
                         const float* A,
                         const float* B,
                         float beta,
                         float* C)
{
    constexpr int BM = 128;
    constexpr int BN = 128;

    dim3 block(128);
    dim3 grid(CEIL_DIV(N, BN), CEIL_DIV(M, BM), 1);

    warptile_kernel<<<grid, block>>>(M, N, K, alpha, A, B, beta, C);

    CHECK_CUDA(cudaGetLastError());
}