## 1.看大局

```
ncu --set basic \
    -k regex:"v" \
    --launch-count 1 \
    ./bench 5 4096 4096 4096
```

```
	----------------------- ----------- ------------
    Metric Name             Metric Unit Metric Value
    ----------------------- ----------- ------------
    DRAM Frequency                  Ghz         5.68
    SM Frequency                    Ghz         1.69
    Elapsed Cycles                cycle     83756235
    Memory Throughput                 %        57.44
    DRAM Throughput                   %        57.44
    Duration                         ms        49.18
    L1/TEX Cache Throughput           %        98.58
    L2 Cache Throughput               %        44.39
    SM Active Cycles              cycle  82548727.50
    Compute (SM) Throughput           %        65.09
    ----------------------- ----------- ------------
```
Compute (SM) Throughput 和 L1/TEX Cache Throughput 都上升了，按理说我们转置读A应该减少了blank conflict应该下降啊，难道vectorizer导致了其他的blank conflict，继续诊断，Compute (SM) Throughput应该是线性化使得访存速度上来了，可以多算点了，反正目前不是compute bound，memory上来，compute就会上来

## 2.看延迟
```
ncu --section WarpStateStats \
    --metrics \
smsp__average_warps_issue_stalled_long_scoreboard_per_issue_active.ratio,\
smsp__average_warps_issue_stalled_short_scoreboard_per_issue_active.ratio,\
smsp__average_warps_issue_stalled_math_pipe_throttle_per_issue_active.ratio,\
smsp__average_warps_issue_stalled_mio_throttle_per_issue_active.ratio \
-k regex:"v" --launch-count 1 ./bench 5 4096 4096 4096
```

```
	--------------------------------------------------------------------------- ----------- ------------
    Metric Name                                                                 Metric Unit Metric Value
    --------------------------------------------------------------------------- ----------- ------------
    smsp__average_warps_issue_stalled_long_scoreboard_per_issue_active.ratio           inst         2.17
    smsp__average_warps_issue_stalled_math_pipe_throttle_per_issue_active.ratio        inst         1.25
    smsp__average_warps_issue_stalled_mio_throttle_per_issue_active.ratio              inst         9.59
    smsp__average_warps_issue_stalled_short_scoreboard_per_issue_active.ratio          inst         0.94
    --------------------------------------------------------------------------- ----------- ------------

    Section: Warp State Statistics
    ---------------------------------------- ----------- ------------
    Metric Name                              Metric Unit Metric Value
    ---------------------------------------- ----------- ------------
    Warp Cycles Per Issued Instruction             cycle        20.84
    Warp Cycles Per Executed Instruction           cycle        20.84
    Avg. Active Threads Per Warp                                   32
    Avg. Not Predicated Off Threads Per Warp                    32.00
    ---------------------------------------- ----------- ------------
```
mio 又上来了 不会真是blank conflict吧

```
 ncu --section SchedulerStats -k regex:"v" --launch-count 1 ./bench 5 4096 4096 4096
```

```
	---------------------------- ----------- ------------
    Metric Name                  Metric Unit Metric Value
    ---------------------------- ----------- ------------
    One or More Eligible                   %        37.92
    Issued Warp Per Scheduler                        0.38
    No Eligible                            %        62.08
    Active Warps Per Scheduler          warp         7.90
    Eligible Warps Per Scheduler        warp         1.03
    ---------------------------- ----------- ------------
```
Eligible上升了，为什么呢线性化加速了访存？

## 3.访存合并

```
ncu --metrics \
l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_ld.ratio,\
l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_st.ratio \
-k regex:"v" --launch-count 1 ./bench 5 4096 4096 4096
```

```
-------------------------------------------------------------------- ----------- ------------
    Metric Name                                                          Metric Unit Metric Value
    -------------------------------------------------------------------- ----------- ------------
    l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_ld.ratio      sector        15.66
    l1tex__average_t_sectors_per_request_pipe_lsu_mem_global_op_st.ratio      sector           16
    -------------------------------------------------------------------- ----------- ------------
```
我去访存合并很差，两次读是可以合并的，但是继续就不行了

A 是行主序,`A[a_row*K + a_col]` 的地址主要由 **`a_row = blockIdx.y*BM + tid/2`** 决定。看一个 warp(tid 0~31):

```
tid:    0    1    2    3    4    5   ...
a_row:  0    0    1    1    2    2   ...   (相邻两线程同行)
a_col:  0    4    0    4    0    4   ...
```

所以 warp 内地址是:

```
t0: A[0*K + 0]     t1: A[0*K + 4]      ← 同一行,连续(这两个其实挨着)
t2: A[1*K + 0]     t3: A[1*K + 4]      ← 跳到下一行,地址 +K (=4096) 个 float!
t4: A[2*K + 0]     ...                 ← 又跳一行
```

**每两个线程就跳一整行(+K×4 字节 = +16KB)。** 32 个线程跨了 16 个不同的行,地址散布在 16 段相距 16KB 的位置 → 一次 LD 请求要碰十几个 cache sector → **sec/req ≈ 15.66**。这就是读合并差的原因。



```
ncu --metrics \
l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_ld.sum,\
l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_st.sum \
-k regex:"v" --launch-count 1 ./bench 5 4096 4096 4096
```
```
-------------------------------------------------------- ----------- ------------
    Metric Name                                              Metric Unit Metric Value
    -------------------------------------------------------- ----------- ------------
    l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_ld.sum                        0
    l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_st.sum                 33554432
    -------------------------------------------------------- ----------- ------------
```
写发生了blank conflict，主要还是A写道AS的时候，没两个线程就回有conflict
![](img/Pasted%20image%2020260605201651.png)

## 总结
有blank conflict 和 访存不合并，那为什么需要warp tile
你现在 `tid/16`、`tid%16` 这种一级映射把 warp 内的线程撒得到处都是,导致读 A、写 C 跨行不合并,写 As 撞 bank。 warp tile 是引入"warp 这一中间层":先决定每个 warp 管哪块连续区域,再决定 warp 内 32 个 lane 怎么排——目的就是让同一个 warp 的访存地址连续(合并)、LDS 地址错开 32 个 bank(无 conflict)、并能用上 broadcast。 换句话说:register tile 解决"一个线程算多少、复用多少"(降 LDS 指令数),warp tile 解决"32 个线程怎么协同访存才高效"(合并 + 无 bank conflict + 广播)。你测出来的那一堆访存问题,正是缺了 warp tile 这一层。

```
naive            → memory bound
+ block tile/smem → DRAM 复用,但 LDS 太多 → MIO bound
+ register tile   → 降 LDS:FMA,缓解 MIO              ← 你在这,但访存映射乱
+ warp tile       → 修好访存合并、bank conflict、广播  ← 下一步,治你现在的病
+ double buffer   → 预取隐藏延迟
```
