## 0、为什么要进行warp tile
所谓warp tile，就是规定一个warp负责算C中的那个区域的元素，其实之前已经有了隐式的warp tile 就是在一个block内按线程id行优先排列，下图之前一个warp负责的C的区域，其实按照之前的分析我们的thread tile已经尽可能的减少的bank conflict和增加访存合并，但只是针对于当前的分块，要是换一个分法，那么我们就要重新设计。
![](img/Pasted%20image%2020260606135707.png)其实之前的分法我们是设计过的，TN=4 是为了让每个 lane 用一个 **float4**(16 字节 = 半个 sector)一次访问连续 4 列。warp 的一行是 16 个 lane**(`laneIdx%8`),16 × float4 = 64 个 float = 256 字节 = 8个连续 sector**,每 2 个 lane 填满 1 个 sector,8 个 sector 全部满载有效数据**,无浪费 → 完美合并。整个 warp 的 4 行各占 4 个满载 sector,跨行只是把一条 store 拆成 4 段,每段独立满载，但是你要是换了一个block 的大小就没有这么凑巧了，一旦 block 尺寸不对齐(如 BN=68),warp 分区会切在非 sector 边界,边缘 warp 落进"只占一半的 sector",sector 里掺无效数据 → 合并崩。 **warp tile 的作用**:用显式 `WM/WN`(选成 sector 的倍数)把每个 warp 的区域对齐到 sector 边界,消除映射人为制造的非对齐。但矩阵尺寸本身的非对齐(N=68 的尾巴)warp tile 救不了,要靠 padding 或边界处理。


## 1、观大局
```

ncu --set basic \
    -k regex:"w" \
    --launch-count 1 \
    ./bench 10 4096 4096 4096
```

```
----------------------- ----------- ------------
    Metric Name             Metric Unit Metric Value
    ----------------------- ----------- ------------
    DRAM Frequency                  Ghz         5.69
    SM Frequency                    Ghz         1.70
    Elapsed Cycles                cycle     65208751
    Memory Throughput                 %        74.82
    DRAM Throughput                   %        74.82
    Duration                         ms        38.09
    L1/TEX Cache Throughput           %        89.34
    L2 Cache Throughput               %        42.88
    SM Active Cycles              cycle  64170655.65
    Compute (SM) Throughput           %        83.33
    ----------------------- ----------- ------------
```
Compute (SM) Throughput和L1/TEX Cache Throughput都很高，这种情况要么很好要么就是很差，往下分析


## 2、看延迟
```
ncu --section WarpStateStats \
    --metrics \
smsp__average_warps_issue_stalled_long_scoreboard_per_issue_active.ratio,\
smsp__average_warps_issue_stalled_short_scoreboard_per_issue_active.ratio,\
smsp__average_warps_issue_stalled_math_pipe_throttle_per_issue_active.ratio,\
smsp__average_warps_issue_stalled_mio_throttle_per_issue_active.ratio \
-k regex:"w" --launch-count 1 ./bench 10 4096 4096 4096
```

```
 --------------------------------------------------------------------------- ----------- ------------
    Metric Name                                                                 Metric Unit Metric Value
    --------------------------------------------------------------------------- ----------- ------------
    smsp__average_warps_issue_stalled_long_scoreboard_per_issue_active.ratio           inst         1.32
    smsp__average_warps_issue_stalled_math_pipe_throttle_per_issue_active.ratio        inst         1.37
    smsp__average_warps_issue_stalled_mio_throttle_per_issue_active.ratio              inst         1.18
    smsp__average_warps_issue_stalled_short_scoreboard_per_issue_active.ratio          inst         0.18
    --------------------------------------------------------------------------- ----------- ------------

    Section: Warp State Statistics
    ---------------------------------------- ----------- ------------
    Metric Name                              Metric Unit Metric Value
    ---------------------------------------- ----------- ------------
    Warp Cycles Per Issued Instruction             cycle         8.36
    Warp Cycles Per Executed Instruction           cycle         8.36
    Avg. Active Threads Per Warp                                32.00
    Avg. Not Predicated Off Threads Per Warp                    32.00
    ---------------------------------------- ----------- ------------

```
延迟也是十分的均衡，继续看

```
 ncu --section SchedulerStats -k regex:"w" --launch-count 1 ./bench 10 4096 4096 4096
```

```
	---------------------------- ----------- ------------
    Metric Name                  Metric Unit Metric Value
    ---------------------------- ----------- ------------
    One or More Eligible                   %        47.29
    Issued Warp Per Scheduler                        0.47
    No Eligible                            %        52.71
    Active Warps Per Scheduler          warp         3.95
    Eligible Warps Per Scheduler        warp         1.15
    ---------------------------- ----------- ------------
```
相较于之前还是升了，

## 3、看访存合并和blank conflict
```
ncu --metrics \
l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_ld.ratio,\
l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_st.ratio \
-k regex:"w" --launch-count 1 ./bench 10 4096 4096 4096
```

```
-------------------------------------------------------------------- ----------- ------------
    Metric Name                                                          Metric Unit Metric Value
    -------------------------------------------------------------------- ----------- ------------
    l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_ld.ratio      sector        15.84
    l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_st.ratio      sector        16.00
    -------------------------------------------------------------------- ----------- ------------
```

好像和之前差不多，但是为什么速度快了起来，我们继续往下看

```
ncu --metrics \
l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_ld.sum,\
l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_st.sum \
-k regex:"w" --launch-count 1 ./bench 10 4096 4096 4096
```

```
-------------------------------------------------------- ----------- ------------
    Metric Name                                              Metric Unit Metric Value
    -------------------------------------------------------- ----------- ------------
    l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_ld.sum                        0
    l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_st.sum                 16777216
    -------------------------------------------------------- ----------- ------------
```
主要还是A的搬运问题，Bs 没有 bank conflict,是因为它用 **128-bit float4 写**,Turing 硬件把一个 warp 的 128-bit shared 访问**按每 8 个 lane 分成一个 phase 分批仲裁**——每 phase 8 lane 各占 4 bank、正好铺满 32 bank、phase 内不撞,所以整体无冲突。这和"32-bit 标量写时 32 个 lane 一起仲裁、容易撞"是两条不同的硬件路径。你旧版的 st conflict 全来自把写 As 的 float4 **拆成 4 条标量**(退回 32-bit 撞 bank),新版改标量+padding 后 As 也不撞了,于是总数归零;Bs 自始至终是 float4、自始至终不撞。

## 总结
目前其实除了AS的black conflict没有解决其他的都挺好的

