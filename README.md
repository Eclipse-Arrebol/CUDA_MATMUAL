# CUDA_MATMUAL

一个从 naive CUDA SGEMM 一步步优化到 shared memory、register tiling、float4、warp tiling、bank conflict 分析和 double buffering 的学习型矩阵乘法项目。

这个仓库的重点不是只给一个最快 kernel，而是把每一步优化为什么有效、什么时候无效、怎么用 Nsight Compute 判断瓶颈都记录下来。代码负责复现实验，`docs/` 负责沉淀分析过程。

## 项目内容

- `kernels/`: 不同阶段的 CUDA SGEMM kernel 实现
- `src/benchmark.cu`: benchmark 入口，按 kernel id 跑性能
- `src/verify.cu`: correctness 入口，和 cuBLAS reference 对比结果
- `include/`: 公共宏、kernel 注册声明、autotuning 模板
- `docs/`: GPU 硬件知识、性能分析方法论和每个 kernel 的 ncu 分析记录

矩阵计算接口统一为：

```cpp
C = alpha * A * B + beta * C
```

其中 A、B、C 都按 row-major 存储。cuBLAS reference 通过交换 A/B 和维度参数适配 row-major 结果。

## 环境要求

- NVIDIA GPU
- CUDA Toolkit，包含 `nvcc`
- cuBLAS
- GNU Make

当前 Makefile 默认编译架构是：

```makefile
ARCH := -arch=sm_75
```

如果在其他显卡上跑，需要按设备改成对应架构，例如 Ada 系列可改成 `sm_89`。改完头文件或架构后建议执行 `make clean && make`。

## 编译

```bash
make
```

会生成两个可执行文件：

- `bench`: 性能测试
- `verify`: 正确性验证

清理生成文件：

```bash
make clean
```

## 正确性验证

默认验证 `id=0`，矩阵尺寸为 `1024 x 1024 x 1024`：

```bash
./verify
```

指定 kernel 和矩阵尺寸：

```bash
./verify <kernel_id> <M> <N> <K>
```

例子：

```bash
./verify 10 1024 1024 1024
```

`verify` 会跑当前 kernel 和 cuBLAS reference，然后输出：

- `max_abs_err`
- `max_rel_err`
- `bad_count`
- `PASS` / `FAIL`

当前误差阈值在 [src/verify.cu](src/verify.cu) 中设置为 `1e-2` 量级。

## 性能测试

默认 benchmark：

```bash
./bench
```

指定 kernel 和矩阵尺寸：

```bash
./bench <kernel_id> <M> <N> <K>
```

例子：

```bash
./bench 10 4096 4096 4096
```

输出格式类似：

```text
warptile_vec_kernel: M=4096 N=4096 K=4096, time=..., GFLOPS=...
```

autotuning 扫描入口：

```bash
./bench autotune 4096 4096 4096
```

## Kernel Id

当前 `bench` / `verify` 注册表主要包含：

| id | Kernel | 说明 |
| --- | --- | --- |
| 0 | cuBLAS reference | `benchmark.cu` 的名字数组目前仍显示为 `dummy_kernel`，但实际函数是 cuBLAS |
| 1 | naive | 一个 thread 计算 C 的一个元素 |
| 2 | smem | A/B 分块搬入 shared memory |
| 3 | block tiling | 1D register tiling，一个 thread 计算多个结果 |
| 4 | 2D block tiling | TM/TN 二维 register tiling |
| 5 | vectorized | float4 向量化访存 |
| 6 | autotuning 64x64x8_8x4 | `launch_at<64,64,8,8,4>` |
| 7 | autotuning 64x64x16_8x4 | `launch_at<64,64,16,8,4>` |
| 8 | autotuning 64x64x8_8x8 | `launch_at<64,64,8,8,8>` |
| 9 | warp tile | warp-level tiling 基线 |
| 10 | warp tile vec | warp tiling + float4 版本 |
| 11 | bank conflict | 搬运映射与 shared memory bank conflict 分析版本 |
| 12 | double buffer | double buffering 版本 |

如果传入非法 id，程序会打印当前注册表。

## 文档导航

建议按这个顺序读：

1. [GPU 前置硬件知识](docs/00%20GPU前置硬件知识.md)
2. [性能分析方法论](docs/01%20性能分析方法论.md)
3. [naive kernel 性能分析](docs/02%20naive%20kernel性能分析.md)
4. [smem kernel 性能分析](docs/03%20smem%20kernel性能分析.md)
5. [register tiling](docs/04%20register%20tiling.md)
6. [vectorizer](docs/05%20vectorizer.md)
7. [warp tile](docs/06%20warp%20tile.md)
8. [bank conflict](docs/07%20blank%20conflict.md)

`docs/6.1.md` 到 `docs/6.5.md` 是阶段性交接文档，记录了每轮实验结论、性能对账、踩坑和下一步计划。想快速了解项目演进，可以从最新的 [docs/6.5.md](docs/6.5.md) 开始。

## Nsight Compute

常用 profiling 命令：

```bash
ncu --set full ./bench 10 4096 4096 4096
```

项目文档里主要关注这些指标：

- kernel duration / elapsed cycles
- Compute(SM) Throughput
- Memory Throughput
- DRAM / L1/TEX / L2 Throughput
- achieved occupancy
- registers per thread
- global memory coalescing
- shared memory bank conflict
- warp stall reason

一个核心经验是：ncu 上某个 throughput 很高，不等于它就是 binding bottleneck。真正要看的是优化它之后 elapsed cycles 是否下降。

## 当前状态

这个项目已经覆盖了 SGEMM 优化中的多条主线：

- 从全局内存 naive 访问开始
- 引入 shared memory 降低重复 global load
- 用 register tiling 提高单线程计算密度
- 用 float4 改善 global memory coalescing
- 用 warp tiling 改变 shared/register 复用结构
- 用 ncu 实证分析 bank conflict 是否真的卡在关键路径上
- 开始引入 double buffering 做 latency hiding

后续可以继续做的方向：

- 清理 benchmark/verify 的 id/name 注册表不一致
- 把 `.o`、可执行文件和 `.ncu-rep` 加入 `.gitignore`
- 固化更多尺寸下的 benchmark 表
- 针对不同 GPU 架构维护独立配置
- 继续完善 double buffering 和更系统的 autotuning 搜索
