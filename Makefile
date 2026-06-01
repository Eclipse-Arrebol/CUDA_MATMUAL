NVCC := nvcc

BENCH_TARGET := bench
VERIFY_TARGET := verify

ARCH := -arch=sm_75
INCLUDES := -I include
OPT := -O3

NVCCFLAGS := $(ARCH) $(INCLUDES) $(OPT)
LDFLAGS := -lcublas

KERNEL_SRCS := $(wildcard kernels/*.cu)
KERNEL_OBJS := $(KERNEL_SRCS:.cu=.o)

BENCH_SRCS := src/benchmark.cu
BENCH_OBJS := $(BENCH_SRCS:.cu=.o)

VERIFY_SRCS := src/verify.cu
VERIFY_OBJS := $(VERIFY_SRCS:.cu=.o)

.PHONY: all clean run verify run-verify

all: $(BENCH_TARGET) $(VERIFY_TARGET)

$(BENCH_TARGET): $(BENCH_OBJS) $(KERNEL_OBJS)
	$(NVCC) $^ -o $@ $(NVCCFLAGS) $(LDFLAGS)

$(VERIFY_TARGET): $(VERIFY_OBJS) $(KERNEL_OBJS)
	$(NVCC) $^ -o $@ $(NVCCFLAGS) $(LDFLAGS)

%.o: %.cu include/common.h include/kernels.h
	$(NVCC) -c $< -o $@ $(NVCCFLAGS)

run: $(BENCH_TARGET)
	./$(BENCH_TARGET)

run-verify: $(VERIFY_TARGET)
	./$(VERIFY_TARGET) 1024 1024 1024

clean:
	rm -f $(BENCH_OBJS) $(VERIFY_OBJS) $(KERNEL_OBJS) $(BENCH_TARGET) $(VERIFY_TARGET)