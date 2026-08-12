#!/usr/bin/env bash
set -e

RESULTS_DIR="csv_results/5_5_NIDS_Performance"
CSV_FILE="${RESULTS_DIR}/nids_gpu_queues_benchmark.csv"

mkdir -p "${RESULTS_DIR}"

echo "Cleaning and compiling NIDS..."
make clean
make

# Initialize CSV file with required format
echo "run_id,rx_queues,throughput_gbps,elapsed_seconds" > "${CSV_FILE}"

# Test sequentially with 1, 2, and 4 queues on the same virtual port
for queues in 1 2 4; do
    echo "=========================================================="
    echo "TEST WITH ${queues} RX QUEUE(S)"
    echo "=========================================================="
    
    sudo rm -rf /var/run/dpdk/rte/* 2>/dev/null

    # Dynamically allocate CPU cores based on the number of queues
    if [ "$queues" -eq 1 ]; then
        CORES="-l 0,1"
    elif [ "$queues" -eq 2 ]; then
        CORES="-l 0,1,2"
    else
        CORES="-l 0,1,2,3,4"
    fi

    # Run the NIDS pipeline and capture output
    OUTPUT=$(sudo ./pipeline_nids $CORES --vdev=net_pcap0,rx_pcap=/dev/shm/MixFile.pcap -- --mode gpu --rx-queues ${queues} Rules/patterns.txt 2>&1)
    
    echo "$OUTPUT"

    # Extract the metrics line from output
    METRICS_LINE=$(echo "$OUTPUT" | grep "METRICS_DATA:" | tail -n 1)

    if [ -n "$METRICS_LINE" ]; then
        THROUGHPUT=$(echo "$METRICS_LINE" | cut -d',' -f3)
        ELAPSED=$(echo "$METRICS_LINE" | cut -d',' -f7)
        echo "queues_${queues},${queues},${THROUGHPUT},${ELAPSED}" >> "${CSV_FILE}"
        echo "  -> [Queue ${queues}] Throughput: ${THROUGHPUT} Gbps | Time: ${ELAPSED} s"
    else
        echo "Warning: Metrics not found for ${queues} queues"
    fi

    sleep 2
done

echo "=========================================================="
echo "Multi-queues tests finished! CSV file generated: ${CSV_FILE}"
echo "=========================================================="