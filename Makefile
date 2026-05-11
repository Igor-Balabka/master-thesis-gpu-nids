CC = gcc
NVCC = nvcc

CFLAGS = -O3 -fopenmp -I.
NVFLAGS = -O3 -arch=sm_80 -Xcompiler -fopenmp -I.
CUDA_LDFLAGS = -lpcap -lcudart -Xcompiler -fopenmp -lm

SRCS_C = main.c payload.c ac.c
SRCS_CU = Kernel/ac_classic.cu Kernel/ac_asychrone.cu Kernel/cuda_utils.cu
SRCS_TEST = unit_tests.c payload.c ac.c

TARGET = nids_gpu
TEST_TARGET = unit_tests

all: $(TARGET)

$(TARGET): $(SRCS_C) $(SRCS_CU)
	$(NVCC) $(NVFLAGS) $(SRCS_C) $(SRCS_CU) -o $(TARGET) $(CUDA_LDFLAGS)

$(TEST_TARGET): $(SRCS_TEST) $(SRCS_CU)
	$(NVCC) $(NVFLAGS) $(SRCS_TEST) $(SRCS_CU) -o $(TEST_TARGET) $(CUDA_LDFLAGS)

info: $(TARGET)
	./$(TARGET) info 

gpu: $(TARGET)
	./$(TARGET) gpu 1 1 Rules/patterns.txt Pcap/MixFile.pcap 256

gpu_async: $(TARGET)
	./$(TARGET) gpu_async 1 1 Rules/patterns.txt Pcap/MixFile.pcap 32 262144 4

cpu: $(TARGET)
	./$(TARGET) cpu 12 1 Rules/patterns.txt Pcap/MixFile.pcap

clean:
	@echo "Removing files"
	rm -f $(TARGET)
	rm -f $(TEST_TARGET)
	rm -f $(ALL_OBJS)
	rm -f benchmark_results.csv
	rm -f *.o Kernel/*.o
	@echo "Done !"

benchmark: $(TARGET)
	sudo ./run_benchmark.sh

test: $(TEST_TARGET)
	./$(TEST_TARGET)

.PHONY: all clean gpu gpu_async cpu