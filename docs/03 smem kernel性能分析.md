## 1.看大局
```
ncu --set basic \
    -k regex:"smem" \
    --launch-count 1 \
    ./bench 2 4096 4096 4096
```

```
 	----------------------- ----------- ------------
    Metric Name             Metric Unit Metric Value
    ----------------------- ----------- ------------
    DRAM Frequency                  Ghz         5.35
    SM Frequency                    Ghz         1.63
    Elapsed Cycles                cycle    409901553
    Memory Throughput                 %        73.56
    DRAM Throughput                   %        23.71
    Duration                         ms       250.65
    L1/TEX Cache Throughput           %        87.25
    L2 Cache Throughput               %        18.12
    SM Active Cycles              cycle 399231388.50
    Compute (SM) Throughput           %        73.56
    ----------------------- ----------- ------------
```
`L1/TEX Cache Throughput` 几乎没有什么变化，但是`Compute (SM) Throughput`下降了，其实是
`L1/TEX Cache Throughput` 也算sharememory的读写,我们只是将数据搬到sharememory但是没有减少它的访问量，而且还多了将dram搬到sharememory的压力，`Compute (SM) Throughput`下降不好判断得继续分析

## 2.看延迟
```
ncu --section WarpStateStats \
    --metrics \
smsp__average_warps_issue_stalled_long_scoreboard_per_issue_active.ratio,\
smsp__average_warps_issue_stalled_short_scoreboard_per_issue_active.ratio,\
smsp__average_warps_issue_stalled_math_pipe_throttle_per_issue_active.ratio,\
smsp__average_warps_issue_stalled_mio_throttle_per_issue_active.ratio \
-k regex:"smem" --launch-count 1 ./bench 2 4096 4096 4096
```

```
	--------------------------------------------------------------------------- ----------- ------------
    Metric Name                                                                 Metric Unit Metric Value
    --------------------------------------------------------------------------- ----------- ------------
    smsp__average_warps_issue_stalled_long_scoreboard_per_issue_active.ratio           inst         6.66
    smsp__average_warps_issue_stalled_math_pipe_throttle_per_issue_active.ratio        inst         0.14
    smsp__average_warps_issue_stalled_mio_throttle_per_issue_active.ratio              inst        27.54
    smsp__average_warps_issue_stalled_short_scoreboard_per_issue_active.ratio          inst         0.29
    --------------------------------------------------------------------------- ----------- ------------

    Section: Warp State Statistics
    ---------------------------------------- ----------- ------------
    Metric Name                              Metric Unit Metric Value
    ---------------------------------------- ----------- ------------
    Warp Cycles Per Issued Instruction             cycle        44.03
    Warp Cycles Per Executed Instruction           cycle        44.03
    Avg. Active Threads Per Warp                                   32
    Avg. Not Predicated Off Threads Per Warp                    31.99
    ---------------------------------------- ----------- ------------

```

smsp__average_warps_issue_stalled_mio_throttle_per_issue_active这个都高达26了，**MIO(Memory Input/Output)指令队列满了**——MIO 管线负责的是 **shared memory 访问、LSU 指令、以及一部分特殊指令**的发射。队列满,意味着 warp 想发一条 MIO 指令(比如一条 `LDS` 读 shared memory),但发射口被前面排队的 MIO 指令堵死,发不进去。所以上面说的`Compute (SM) Throughput`下降应该是MIO 堵住了导致拿不到数据不好算了

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

**均每个周期,每个调度器手里能挑的 eligible warp 还不到一个**——也就是大部分周期调度器无 warp 可发,直接 no_eligible 空转。这正是 smem 版本性能上不去的直接证据。
```
LDS 指令密度过高
   ↓
MIO 队列被塞满 → mio_throttle = 27.54
   ↓
绝大多数 warp 的下一条指令是 LDS,但 MIO 满了发不进去
   ↓
这些 warp 全部 not eligible(被 mio_throttle 卡住)
   ↓
每个 scheduler 每周期能挑的 eligible warp < 1 → 0.80
   ↓
no_eligible 周期占比高 → SM 空转 → Compute throughput 上不去
```


## 3.看访存合并
```
ncu --metrics \
l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_ld.ratio,\
l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_st.ratio \
-k regex:"smem" --launch-count 1 ./bench 2 4096 4096 4096
```

```
	-------------------------------------------------------------------- ----------- ------------
    Metric Name                                                          Metric Unit Metric Value
    -------------------------------------------------------------------- ----------- ------------
    l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_ld.ratio      sector            4
    l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_st.ratio      sector            4
    -------------------------------------------------------------------- ----------- ------------
```
现在全局访存只剩**把 tile 从 DRAM 搬进 shared memory** 这一种,而这个搬运你写成了完美连续访问 → 32 线程连续读 128B → 干净的 4 sector。**关键**:全局 sec/req 变 4 不是因为"算得多了",是因为现在全局内存只在 tile 加载时被碰一次,而这一次你写得很规整。复用发生在 shared memory 那一侧,和全局 sec/req 是两回事。

十分完美的访存合并，但是都合并怎么好了，为什么性能还是不好了，我觉得可以判断为MIO bound，就是当前加载内存数据的速度已经更不上计算的速度了尽管我们的访存合并十分的完美，也就是说一次load一次compute不行了，最好是一次load，多次compute，我们换了sharememory其实就是可以进行多次计算了，两块小的sharememory其实就是两个小矩阵，将这个矩阵算完，在进行一次BK的循环其实就可以得到一块c的结果，其实这个sharememory就是将Dram上的数据放在的读速度更快的地方，这个trade-off其实就是将dram数据移到sharememory上的时间和sharemory优化读写的时间，但是你说你花了大把时间将dram数据移到sharememory上，但是你就读写一次，这不血亏吗，要多算几次才能将这个时间赚回来啊


## 总结
MIO 堵塞(mio_throttle 高)导致发射率下降、性能上不去。根因是 **LDS 指令太多**把 MIO 队列打满。解决方向是**减少 LDS 指令条数**,让搬进来的每个数被复用更多次:

- **register tiling**:把 smem 数据攒进寄存器再复用,一条 LDS 喂多个 FMA(根治)
- **LDS.128 向量化**:一条指令读 128 bit,指令数降到 1/4(缓解)
