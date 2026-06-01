## ncu性能测试
```
ncu --set basic ./bench 1 4096 4096 4096
```
重点看
Duration                 kernel 时间
SM Throughput            SM 算力利用率
Memory Throughput        显存带宽利用率
Occupancy                占用率
Global Memory Load/Store 显存访问效率

## 应该怎么看ncu报告

其实重要的问题就是这个kernel
```
1. 这个 kernel 跑了多久？
2. 算力利用率高不高？
3. 显存/缓存压力大不大？
4. occupancy 高不高？
5. block/grid 配置合不合理？
6. 下一步该优化计算，还是优化访存？
```

首先看Duration，他就是当前kernel运行的时间
其次看Compute (SM) Throughput：主要还是看sm忙不忙
再看Memory Throughput，就是当前kernel给显存的综合压力
DRAM Throughput，接近“真实显存带宽利用率”
Registers Per Thread，每个线程需要多少寄存器
Occupancy，并行度高不高

怎么判断是 compute bound 还是 memory bound？



同一个 warp 里相邻的两个 thread(col 差 1,row 相同),在内层循环同一个 k:

- 读 A[row*K+k]：两个 thread 读到的是同一个地址还是不同地址？
- 读 B[k*N+col]：两个 thread 读到的地址相差多少？连续吗？

- 读 B:相邻 thread 地址差 1 个 float → 连续 → 完美合并访存(coalesced)。一个 warp 32 个 thread 读的是连续 128 字节,正好一个内存事务搞定。
- 读 A:同一 warp 所有 thread 读同一个地址 → 这不是"跨 thread 的合并问题",而是广播(broadcast),硬件对"所有 thread 读同一地址"也处理得很好。

```
(base) hp@Miliar:~/CUDA_MATMUAL$ ./bench 1 1024 1024 1024
naive_kernel: M=1024 N=1024 K=1024, time=5.3903 ms, GFLOPS=398.40
(base) hp@Miliar:~/CUDA_MATMUAL$ ./bench 1 4096 4096 4096
naive_kernel: M=4096 N=4096 K=4096, time=276.9738 ms, GFLOPS=496.22
```

但是为什么性能怎么差呢
Compute (SM) Throughput: 82.46%
Memory Throughput: 82.46%(注意这俩一模一样)
DRAM Throughput: 21.71%
L1/TEX Cache Throughput: 84.31%
L2 Cache Throughput: 14.23%
Achieved Occupancy: 99.81%
所以真正的瓶颈是：L1/TEX cache 的吞吐被打满了，是访问 L1 的次数太多——每个 thread 内层循环 K=4096 次，每次都发两条 load 指令（读 A、读 B）打到 L1

## 怎么想到这个算法的
这个我觉得想起来还是挺简单的，就是一个thread对应c的一个元素
那其实就是再到每个元素对应的A的行起始值和B的列起始值，内层加个K的循环就得到了一个元素的值



