## 1.看大局
```
ncu --set basic \
    -k regex:"naive" \
    --launch-count 1 \
    ./bench 1 4096 4096 4096
```

```
  naive_kernel(int, int, int, float, const float *, const float *, float, float *) (128, 128, 1)x(32, 32, 1), Context 1, Stream 7, Device 0, CC 7.5
    Section: GPU Speed Of Light Throughput
    ----------------------- ----------- ------------
    Metric Name             Metric Unit Metric Value
    ----------------------- ----------- ------------
    DRAM Frequency                  Ghz         5.53
    SM Frequency                    Ghz         1.67
    Elapsed Cycles                cycle    523698583
    Memory Throughput                 %        82.58
    DRAM Throughput                   %        21.72
    Duration                         ms       312.91
    L1/TEX Cache Throughput           %        84.26
    L2 Cache Throughput               %        14.71
    SM Active Cycles              cycle 509987592.80
    Compute (SM) Throughput           %        82.58
    ----------------------- ----------- ------------
```

判读:Compute 和 Memory 完全相等(82.58%),且都约等于 L1/TEX(84.26%)。这不是"算力和带宽双满",而是**同一条 L1/TEX LSU 管线同时顶满了两个口径**——LSU 既进 SM 算力口径,它发出的访存又进 Memory 口径。真正的 DRAM 才 21.7%,外部带宽闲着。

## 2.看延迟


```
ncu --section WarpStateStats \
    --metrics \
smsp__average_warps_issue_stalled_long_scoreboard_per_issue_active.ratio,\
smsp__average_warps_issue_stalled_short_scoreboard_per_issue_active.ratio,\
smsp__average_warps_issue_stalled_math_pipe_throttle_per_issue_active.ratio,\
smsp__average_warps_issue_stalled_mio_throttle_per_issue_active.ratio \
-k regex:"naive" --launch-count 1 ./bench 1 4096 4096 4096
```

```
	---------------------------------------- ----------- ------------
    Metric Name                              Metric Unit Metric Value
    ---------------------------------------- ----------- ------------
    Warp Cycles Per Issued Instruction             cycle        32.68
    Warp Cycles Per Executed Instruction           cycle        32.68
    Avg. Active Threads Per Warp                                   32
    Avg. Not Predicated Off Threads Per Warp                    31.99
    ---------------------------------------- ----------- ------------
   
   	--------------------------------------------------------------------------- ----------- ------------
    Metric Name                                                                 Metric Unit Metric Value
    --------------------------------------------------------------------------- ----------- ------------
    smsp__average_warps_issue_stalled_long_scoreboard_per_issue_active.ratio           inst         1.79
    smsp__average_warps_issue_stalled_math_pipe_throttle_per_issue_active.ratio        inst         0.19
    smsp__average_warps_issue_stalled_mio_throttle_per_issue_active.ratio              inst         0.00
    smsp__average_warps_issue_stalled_short_scoreboard_per_issue_active.ratio          inst         0.00
    --------------------------------------------------------------------------- ----------- ------------
```

`Issued Instruction`就是每次发送指令需要等待的cycle，32是一个很大的数值，结合之前的我们怀疑LSU占用的大量的资源，我们可以推断大量的时间可以是浪费在load和store上。
`long_scoreboard` stall 专指 warp 在等**远距离内存操作**返回结果，具体是：
- global memory load（L2/DRAM）
- local memory load（寄存器溢出）
**不包括** shared memory（那个是 `short_scoreboard`）。


```
 ncu --section SchedulerStats -k regex:"smem" --launch-count 1 ./bench 2 4096 4096 4096
```

```
    ---------------------------- ----------- ------------
    Metric Name                  Metric Unit Metric Value
    ---------------------------- ----------- ------------
    One or More Eligible                   %        18.15
    Issued Warp Per Scheduler                        0.18
    No Eligible                            %        81.85
    Active Warps Per Scheduler          warp         8.00
    Eligible Warps Per Scheduler        warp         0.80
    ---------------------------- ----------- ------------
```
Eligible Warps Per Scheduler十分的低，说明每个 scheduler 有约 8 个 active warp，但平均只有 **0.95 个 warp 是 ready 的**。

## 3.看访存合并
```
ncu --metrics \
l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_ld.ratio,\
l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_st.ratio \
-k regex:"naive" --launch-count 1 ./bench 1 4096 4096 4096
```

```
	-------------------------------------------------------------------- ----------- ------------
    Metric Name                                                          Metric Unit Metric Value
    -------------------------------------------------------------------- ----------- ------------
    l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_ld.ratio      sector         2.50
    l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_st.ratio      sector            4
    -------------------------------------------------------------------- ----------- ------------
```
这个就是访存合并，ld就是读，value的单位是sector，一个sector是32byte，32 个线程连续写float的话其实就是4x32=128个byte，其实就是4sectors，也就是说一次ld指令最好就是4，那这个2.5是这么来的其实就是A一次ld就一个sector，但是B是连续的一个4个sector一平均就是2.5了

```
ncu --metrics \
l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_ld.sum,\
l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_st.sum \
-k regex:"naive" --launch-count 1 ./bench 1 4096 4096 4096
```

```
	-------------------------------------------------------- ----------- ------------
    Metric Name                                              Metric Unit Metric Value
    -------------------------------------------------------- ----------- ------------
    l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_ld.sum                        0
    l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_st.sum                        0
    -------------------------------------------------------- ----------- ------------
```
这个可以看到bank conflict是没有啊，因为我们就没有用sharememory

## 结论


- `long_scoreboard` 碾压 → 病灶是**等全局内存返回**(L1TEX scoreboard 依赖)。
- `Warp Cycles/Issued = 32.68` → 每发一条指令要熬 32 周期,这种量级的等待只可能来自全局访存延迟,和 long_scoreboard 互相印证。
- `Active 7.99 / Eligible 0.95` → occupancy 顶满(8 warp/scheduler 是 1650S 上限),但平均不到 1 个 warp ready。**32 个 warp 几乎同时卡在等内存上,谁也补不了谁的位。**

所以我们要解决的问题就是load时间过长的问题，怎么解决呢，就是将数据放到读写速度更快的地方


