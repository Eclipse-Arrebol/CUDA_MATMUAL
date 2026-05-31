NVCC := nvcc

TARGET := bench

ARCH := -arch=sm_89
INCLUDES := -I include
OPT := -O3

NVCCFLAGS := $(ARCH) $(INCLUDES) $(OPT)

SRCS := src/benchmark.cu $(wildcard kernels/*.cu)
OBJS := $(SRCS:.cu=.o)

.PHONY: all clean run

all: $(TARGET)

$(TARGET): $(OBJS)
	$(NVCC) $(OBJS) -o $@ $(NVCCFLAGS)

%.o: %.cu include/common.h
	$(NVCC) -c $< -o $@ $(NVCCFLAGS)

run: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(OBJS) $(TARGET)