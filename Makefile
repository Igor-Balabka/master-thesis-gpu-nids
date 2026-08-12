# Compilers for C code and CUDA code
CC       = gcc
NVCC     = nvcc

# Fetch DPDK compiler flags and linker libraries automatically
DPDK_CFLAGS  = $(shell pkg-config --cflags libdpdk)
DPDK_LDFLAGS = $(shell pkg-config --libs   libdpdk)

# Optimization and warning flags for C and CUDA
CFLAGS  = -O3 -march=native -fopenmp -I. $(DPDK_CFLAGS) -Wall -Wextra
NVFLAGS = -O3 -arch=sm_86 -I. \
          --use_fast_math \
          --generate-line-info \
          -Xcompiler "-fPIC -Wall -Wextra $(DPDK_CFLAGS)"

# Linker flags to include DPDK, CUDA, and math libraries
LDFLAGS = $(DPDK_LDFLAGS) -lcudart -lstdc++ -lm -lpcap -fopenmp

# Shared object files required for targets
OBJS = ac.o payload.o dpdk.o gpu_engine.o

TARGET_MAIN  = pipeline_nids
TARGET_TESTS = run_tests

.PHONY: all clean run-gpu run-cpu run-gpu-5q run-gpu-mem test

all: $(TARGET_MAIN) $(TARGET_TESTS)

ac.o: ac.c ac.h config.h
	$(CC) $(CFLAGS) -c ac.c -o $@

payload.o: payload.c payload.h config.h
	$(CC) $(CFLAGS) -c payload.c -o $@

dpdk.o: dpdk.c config.h ac.h
	$(CC) $(CFLAGS) -c dpdk.c -o $@

gpu_engine.o: gpu_engine.cu gpu_engine.h config.h ac.h payload.h
	$(NVCC) $(NVFLAGS) -c gpu_engine.cu -o $@

main.o: main.c config.h ac.h gpu_engine.h
	$(CC) $(CFLAGS) -c main.c -o $@

unit_tests.o: unit_tests.c config.h ac.h payload.h gpu_engine.h
	$(CC) $(CFLAGS) -c unit_tests.c -o $@

$(TARGET_MAIN): main.o $(OBJS)
	$(CC) main.o $(OBJS) -o $@ $(LDFLAGS)
	@echo "Main application compiled successfully: ./$(TARGET_MAIN)"

$(TARGET_TESTS): unit_tests.o $(OBJS)
	$(CC) unit_tests.o $(OBJS) -o $@ $(LDFLAGS)
	@echo "Test suite compiled successfully: ./$(TARGET_TESTS)"

# CPU baseline mode (1 queue)
run-cpu: $(TARGET_MAIN)
	sudo rm -rf /var/run/dpdk/rte/* 2>/dev/null
	sudo ./$(TARGET_MAIN) -l 0,1,2,3,4,5,6,7,8 --vdev="net_pcap0,rx_pcap=Pcap/MixFile.pcap" -- --mode cpu Rules/patterns.txt

# Standard GPU mode (1 queue)
run-gpu: $(TARGET_MAIN)
	sudo rm -rf /var/run/dpdk/rte/* 2>/dev/null
	sudo ./$(TARGET_MAIN) -l 0,1,2 --vdev="net_pcap0,rx_pcap=Pcap/MixFile.pcap" -- --mode gpu --rx-queues 1 Rules/patterns.txt

# GPU multi-queues mode (2 RX queues)
run-gpu-2q: $(TARGET_MAIN)
	sudo rm -rf /var/run/dpdk/rte/* 2>/dev/null
	sudo ./$(TARGET_MAIN) -l 0,1,2,3 \
		--vdev="net_pcap0,rx_pcap=Pcap/MixFile_2q_1.pcap,rx_pcap=Pcap/MixFile_2q_2.pcap" \
		-- --mode gpu --rx-queues 2 Rules/patterns.txt

# GPU multi-queues mode (4 RX queues with isolated batches)
run-gpu-4q: $(TARGET_MAIN)
	sudo rm -rf /var/run/dpdk/rte/* 2>/dev/null
	sudo ./$(TARGET_MAIN) -l 0,1,2,3,4 \
		--vdev="net_pcap0,rx_pcap=Pcap/MixFile_4q_1.pcap,rx_pcap=Pcap/MixFile_4q_2.pcap,rx_pcap=Pcap/MixFile_4q_3.pcap,rx_pcap=Pcap/MixFile_4q_4.pcap" \
		-- --mode gpu --rx-queues 4 --batches-per-queue 128 Rules/patterns.txt
        
# GPU in-memory mode for maximum throughput measurement
run-gpu-mem: $(TARGET_MAIN)
	sudo rm -rf /var/run/dpdk/rte/* 2>/dev/null
	sudo ./$(TARGET_MAIN) -l 0,1 --vdev="net_pcap0,rx_pcap=Pcap/MixFile.pcap" -- --mode gpu --in-memory Rules/patterns.txt

test: $(TARGET_TESTS)
	./$(TARGET_TESTS)

clean:
	rm -f *.o $(TARGET_MAIN) $(TARGET_TESTS)
	@echo "Cleanup completed."