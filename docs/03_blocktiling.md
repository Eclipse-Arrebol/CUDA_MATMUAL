## 怎么想到这个算法的
原来是一个thread负责一个元素的，看到ncu的报告其实还是memory的压力比较大，而且我们可以发现其实使用到的内存还有很多重复的，比如C的同一列元素，其实用到的B的元素也是相同的，所以自然就想到了，一个thread负责多个元素，我这里是使用一个thread负责C的8个同一列的元素，这样原来一个tile是64x64，就要变成64x8了（这是针对于A来说的），所以A的tile就是64x8,b的tile就是8x64了

那原来两个循环分别是遍历每一个tile，遍历每个tile的元素，但是现在一个thread算8个元素所以其实要加一个循环就是把8个元素的结果都算一个，所以这个结果就要使用一个数组保存了

说一个元素对应的坐标怎么算，先看怎么到share_memory，其实这个共享内存就是对应的每一个tile，一个tile里面是有64x8个元素，由8*64个thread负责，所以A，B都是使用一个thread移动进来，又因为把blocksize干好设置为8x64，所以其实可以把一个小tile看成一个小矩阵算出他的行和列
```text
int tid = threadIdx.x + threadIdx.y*blockDim.x;
int a_row = tid / BK + BM * blockIdx.y;
int a_col = bk + tid % BK;
int b_row = bk + tid / BN;
int b_col = blockIdx.x * BN + tid % BN;

As[tid / BK][tid % BK] = (a_row < M && a_col < K) ? A[a_row * K + a_col] : 0.0f;
Bs[tid / BN][tid % BN] = (b_row < K && b_col < N) ? B[b_row * N + b_col] : 0.0f;
```

接下来看中间累加的结果是怎么算的，其实在blocksize设计的时候原来是64*64的由于一个thread负责8个元素所以写了,这个其实有点误导性，其实就是行有8个thread负责，列有64
```
dim3 block(64,8,1);
```
所以结果就是B的固定一列拿出来，和A的8个不同行相乘
```
for(int k=0;k<BK;k++)
{
    float b = Bs[k][tid%BN];
    for(int i=0;i<TM;i++)
    {
        acc[i]+=As[tid/BN*TM + i][k] * b;
    }
}
```

最后就是怎么对应C的结果的了，依旧是看tile中的分类，行就是tid/64*（1~8）列就是tid/8。接下来就是看第几个tie了，一个tile算C的64*64，第几个行tile就是blockIdx.y这个乘64就是c的行的起始地址，同理列也可以算出来
```
int c_col=tid%64;
int c_row_block=tid/64;
for (int i = 0; i < TM; i++) {
    int global_row = blockIdx.y * BM + c_row_block * TM + i;
    int global_col = blockIdx.x * BN + c_col;
    if (global_row < M && global_col < N) {
        C[global_row * N + global_col] = alpha * acc[i] + beta * C[global_row * N + global_col];
    }
}
```

