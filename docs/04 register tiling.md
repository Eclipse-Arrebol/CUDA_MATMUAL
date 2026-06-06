## 1、看大局
```
ncu --set basic \
    -k regex:"D" \
    --launch-count 1 \
    ./bench 4 4096 4096 4096
```

```
	----------------------- ----------- ------------
    Metric Name             Metric Unit Metric Value
    ----------------------- ----------- ------------
    DRAM Frequency                  Ghz         5.51
    SM Frequency                    Ghz         1.66
    Elapsed Cycles                cycle    108456000
    Memory Throughput                 %        49.13
    DRAM Throughput                   %        45.34
    Duration                         ms        64.91
    L1/TEX Cache Throughput           %        98.26
    L2 Cache Throughput               %        34.57
    SM Active Cycles              cycle    106388071
    Compute (SM) Throughput           %        53.01
    ----------------------- ----------- ------------
```
`L1/TEX Cache Throughput` 上升了，但是`Compute (SM) Throughput`下降了，其实是
register tile 的预期是**减少 LDS 指令 → L1/TEX 持平或下降 → mio_throttle 下降**,具体原因不好判断
`Compute (SM) Throughput`下降不好判断得继续分析


## 2.看延迟
```
ncu --section WarpStateStats \
    --metrics \
smsp__average_warps_issue_stalled_long_scoreboard_per_issue_active.ratio,\
smsp__average_warps_issue_stalled_short_scoreboard_per_issue_active.ratio,\
smsp__average_warps_issue_stalled_math_pipe_throttle_per_issue_active.ratio,\
smsp__average_warps_issue_stalled_mio_throttle_per_issue_active.ratio \
-k regex:"D" --launch-count 1 ./bench 4 4096 4096 4096
```

```
 	--------------------------------------------------------------------------- ----------- ------------
    Metric Name                                                                 Metric Unit Metric Value
    --------------------------------------------------------------------------- ----------- ------------
    smsp__average_warps_issue_stalled_long_scoreboard_per_issue_active.ratio           inst         1.59
    smsp__average_warps_issue_stalled_math_pipe_throttle_per_issue_active.ratio        inst         0.75
    smsp__average_warps_issue_stalled_mio_throttle_per_issue_active.ratio              inst         3.93
    smsp__average_warps_issue_stalled_short_scoreboard_per_issue_active.ratio          inst         2.54
    --------------------------------------------------------------------------- ----------- ------------

    Section: Warp State Statistics
    ---------------------------------------- ----------- ------------
    Metric Name                              Metric Unit Metric Value
    ---------------------------------------- ----------- ------------
    Warp Cycles Per Issued Instruction             cycle        13.42
    Warp Cycles Per Executed Instruction           cycle        13.42
    Avg. Active Threads Per Warp                                32.00
    Avg. Not Predicated Off Threads Per Warp                    31.91
    ---------------------------------------- ----------- ------------
```
四项延迟比较平均，最高的还是mio，应该是访存指令太多了，可以考虑使用向量化了，减少指令数量

```
 ncu --section SchedulerStats -k regex:"D" --launch-count 1 ./bench 4 4096 4096 4096
```

```
	---------------------------- ----------- ------------
    Metric Name                  Metric Unit Metric Value
    ---------------------------- ----------- ------------
    One or More Eligible                   %        37.03
    Issued Warp Per Scheduler                        0.37
    No Eligible                            %        62.97
    Active Warps Per Scheduler          warp         4.97
    Eligible Warps Per Scheduler        warp         0.73
    ---------------------------- ----------- ------------
```
`Eligible = 0.73 / No Eligible = 62.97%`:No Eligible 从 smem 的 82% 降到 63%,延迟开始被填上了。:Active 降了但 No-Eligible 也降了 → **不再靠 warp 数量藏延迟,改靠单线程内部的 ILP 藏延迟**。




## 3.看访存合并

```
ncu --metrics \
l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_ld.ratio,\
l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_st.ratio \
-k regex:"D" --launch-count 1 ./bench 4 4096 4096 4096
```

```
-------------------------------------------------------------------- ----------- ------------
    Metric Name                                                          Metric Unit Metric Value
    -------------------------------------------------------------------- ----------- ------------
    l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_ld.ratio      sector         3.98
    l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_st.ratio      sector           16
    -------------------------------------------------------------------- ----------- ------------
```
下图是AS的搬运过程，可以看到BK设计的很好，刚好是8的倍数，访问一行刚好是一个sector，所以一个warp访问的sector刚好就是4，同样B也是4，所以读的访存合并是十分好的了。
![](img/Pasted%20image%2020260606133301.png)


读还好，但是写C的合并的不好，这个原因也很明显就是一个thread负责多个元素之后写就不是连续的了,
- 原因:register tile 后一个线程负责 TM×TN 个 C 元素,直接 `C[row][col]=acc[i][j]` 逐个写 → 地址跳跃 → 不合并。
- 解法:**写回时也向量化**——把 `acc` 的一行用 `float4`(`reinterpret_cast<float4*>`)一次写 128 bit,sec/req 能从 16 拉回到 4。这和 LDS.128 是配套的。
**![](img/Pasted%20image%2020260606134019.png)**



```
ncu --metrics \
l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_ld.sum,\
l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_st.sum \
-k regex:"D" --launch-count 1 ./bench 4 4096 4096 4096
```

```
-------------------------------------------------------- ----------- ------------
    Metric Name                                              Metric Unit Metric Value
    -------------------------------------------------------- ----------- ------------
    l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_ld.sum                268435456
    l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_st.sum                        0
    -------------------------------------------------------- ----------- ------------
```

读数据一堆blank conflict，这应该就是一开始L1/TEX 上去的原因，那是搬运寄存器的时候出现来的blankconflict，看下面这个图也很容易发现在AS搬运到regA的时候发生的blank conflict，多个线程访问同一个blank的不同元素，但是BS搬运到regB的时候没有这个问题其实就是BS的过程是AS的转置，刚好错开了

![](img/Pasted%20image%2020260605192018.png)


## 总结
该 kernel 存在 **shared memory bank conflict**(LDS 访问布局未错开 bank,单条 LDS 被拆成多次 transaction),同时 MIO 仍有一定拥堵。

- bank conflict → 用 **padding(BK+1)或 swizzle 重排**消除;
- MIO 拥堵 → 用 **LDS.128 向量化 / register tile** 降低 LDS 指令数。
