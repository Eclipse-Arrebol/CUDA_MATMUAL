#pragma once
void launch_naive_kernel(int M, int N, int K, float alpha,
                         const float* A, const float* B,
                         float beta, float* C);
