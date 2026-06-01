#pragma once
void launch_naive_kernel(int M, int N, int K, float alpha,
                         const float* A, const float* B,
                         float beta, float* C);

void launch_smem_kernel(int M, int N, int K, float alpha,
                         const float* A, const float* B,
                         float beta, float* C);


void launch_blocktiling_kernel(int M, int N, int K,
                         float alpha,
                         const float* A,
                         const float* B,
                         float beta,
                         float* C);

void launch_2Dblocktiling_kernel(int M, int N, int K,
                         float alpha,
                         const float* A,
                         const float* B,
                         float beta,
                         float* C);