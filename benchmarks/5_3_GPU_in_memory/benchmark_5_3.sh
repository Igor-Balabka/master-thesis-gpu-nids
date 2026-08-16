#!/bin/bash

sudo killall -9 gpu_vram_benchmark 2>/dev/null || true

PCAP_PATH="/dev/shm/MixFile.pcap"
RULES_PATH="../../Rules/patterns.txt"

echo "Starting the 5 benchmark runs (120s per run)..."

for i in {1..5}
do
    echo "----------------------------------------"
    echo "Run $i / 5"
    echo "----------------------------------------"
    sudo ./gpu_vram_benchmark $PCAP_PATH $RULES_PATH
    
    sleep 2
done

echo "Benchmark series finished! Results saved in csv_results/GPU_in_memory/gpu_vram_results.csv"