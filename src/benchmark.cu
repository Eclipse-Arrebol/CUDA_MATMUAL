#include "../include/common.h"
#include "../include/kernels.h"
#include <cstdio>
#include <cstdlib>


__global__ void dummy_kernel(int M, int N, int K,
                             float alpha,
                             const float* A,
                             const float* B,
                             float beta,
                             float* C)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    int size = M * N;

    if (idx < size) {
        C[idx] = 0.0f;
    }
}

void launch_dummy_kernel(int M, int N, int K,
                         float alpha,
                         const float* A,
                         const float* B,
                         float beta,
                         float* C)
{
    int size = M * N;
    int block_size = 256;
    int grid_size = (size + block_size - 1) / block_size;

    dummy_kernel<<<grid_size, block_size>>>(M, N, K, alpha, A, B, beta, C);

    CHECK_CUDA(cudaGetLastError());
}

void init_matrix(float* mat, int size)
{
    for (int i = 0; i < size; i++) {
        mat[i] = ((i % 17) - 8) * 0.1f;
    }
}




void benchmark_kernel(const char* name,
                      KernelFn kernel,
                      int M, int N, int K,
                      int warmup_iters,
                      int repeat_iters)
{
    float alpha = 1.0f;
    float beta = 0.0f;

    size_t bytes_A = (size_t)M * K * sizeof(float);
    size_t bytes_B = (size_t)K * N * sizeof(float);
    size_t bytes_C = (size_t)M * N * sizeof(float);

    float* h_A = (float*)malloc(bytes_A);
    float* h_B = (float*)malloc(bytes_B);
    float* h_C = (float*)malloc(bytes_C);

    if (!h_A || !h_B || !h_C) {
        printf("Host malloc failed\n");
        exit(1);
    }

    init_matrix(h_A, M * K);
    init_matrix(h_B, K * N);
    init_matrix(h_C, M * N);

    float* d_A = nullptr;
    float* d_B = nullptr;
    float* d_C = nullptr;

    CHECK_CUDA(cudaMalloc(&d_A, bytes_A));
    CHECK_CUDA(cudaMalloc(&d_B, bytes_B));
    CHECK_CUDA(cudaMalloc(&d_C, bytes_C));

    CHECK_CUDA(cudaMemcpy(d_A, h_A, bytes_A, cudaMemcpyHostToDevice));
    CHECK_CUDA(cudaMemcpy(d_B, h_B, bytes_B, cudaMemcpyHostToDevice));
    CHECK_CUDA(cudaMemcpy(d_C, h_C, bytes_C, cudaMemcpyHostToDevice));

    for (int i = 0; i < warmup_iters; i++) {
        kernel(M, N, K, alpha, d_A, d_B, beta, d_C);
    }

    CHECK_CUDA(cudaDeviceSynchronize());

    cudaEvent_t start;
    cudaEvent_t stop;

    CHECK_CUDA(cudaEventCreate(&start));
    CHECK_CUDA(cudaEventCreate(&stop));

    CHECK_CUDA(cudaEventRecord(start));

    for (int i = 0; i < repeat_iters; i++) {
        kernel(M, N, K, alpha, d_A, d_B, beta, d_C);
    }

    CHECK_CUDA(cudaEventRecord(stop));
    CHECK_CUDA(cudaEventSynchronize(stop));

    float total_ms = 0.0f;
    CHECK_CUDA(cudaEventElapsedTime(&total_ms, start, stop));

    float avg_ms = total_ms / repeat_iters;

    double flops = 2.0 * (double)M * N * K;
    double gflops = flops / (avg_ms / 1000.0) / 1e9;

    printf("%s: M=%d N=%d K=%d, time=%.4f ms, GFLOPS=%.2f\n",
           name, M, N, K, avg_ms, gflops);

    CHECK_CUDA(cudaEventDestroy(start));
    CHECK_CUDA(cudaEventDestroy(stop));

    CHECK_CUDA(cudaFree(d_A));
    CHECK_CUDA(cudaFree(d_B));
    CHECK_CUDA(cudaFree(d_C));

    free(h_A);
    free(h_B);
    free(h_C);
}

KernelFn g_kernels[] = {launch_dummy_kernel,launch_naive_kernel,launch_smem_kernel,launch_blocktiling_kernel,launch_2Dblocktiling_kernel};
const char* g_names[] = {"dummy_kernel","naive_kernel","smem_kernel","blocktiling_kernel","Dblocktiling_kernel"};

int main(int argc,char** argv)
{
    int M = 1024;
    int N = 1024;
    int K = 1024;
    int id=0;
    int num_kernels = sizeof(g_kernels) / sizeof(g_kernels[0]);
    if (argc == 5) {
        id = atoi(argv[1]);
        M = atoi(argv[2]);
        N = atoi(argv[3]);
        K = atoi(argv[4]);
    } else if (argc != 1) {
        printf("Usage: %s [kernel_id M N K]\n", argv[0]);
        printf("Example: %s 4 1024 1024 1024\n", argv[0]);
        return 1;
    }
    if (id < 0 || id >= num_kernels) {
        for(int i=0;i<num_kernels;i++)
        {
            printf("idx:%d,kernel:%s\n",i,g_names[i]);
        }
        return 1;
    }

    int warmup_iters = 2;
    int repeat_iters = 10;

    benchmark_kernel(g_names[id],
                     g_kernels[id],
                     M, N, K,
                     warmup_iters,
                     repeat_iters);

    return 0;
}
