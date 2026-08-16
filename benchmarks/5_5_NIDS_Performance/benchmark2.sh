#!/usr/bin/env bash
set -e

RESULTS_DIR="csv_results/5_5_NIDS_Performance"
CSV_FILE="${RESULTS_DIR}/nids_gpu_in_memory_benchmark.csv"

mkdir -p "${RESULTS_DIR}"

echo "Cleaning and compiling NIDS..."
make clean
make

# Initialize CSV file with the required header
echo "run_id,rx_queues,throughput_gbps,elapsed_seconds,total_matches" > "${CSV_FILE}"

NUM_RUNS=5

# Loop over the number of queues (1, 2, and 4)
for queues in 1 2 4; do
    echo "=========================================================="
    echo "IN-MEMORY TEST WITH ${queues} RX QUEUE(S) (${NUM_RUNS} Runs)"
    echo "=========================================================="
    
    # Dynamically allocate CPU cores based on the number of queues
    if [ "$queues" -eq 1 ]; then
        CORES="-l 0,1,2"
    elif [ "$queues" -eq 2 ]; then
        CORES="-l 0,1,2,3"
    else
        CORES="-l 0,1,2,3,4"
    fi

    # Repeat each test 5 times
    for run in $(seq 1 ${NUM_RUNS}); do
        echo "----------------------------------------------------------"
        echo "${queues} Queue(s) - RUN ${run} / ${NUM_RUNS}"
        echo "----------------------------------------------------------"
        
        sudo rm -rf /var/run/dpdk/rte/* 2>/dev/null

        # Run the In-Memory benchmark
        OUTPUT=$(sudo ./pipeline_nids $CORES -- --mode gpu --in-memory --rx-queues ${queues} Rules/patterns.txt 2>&1)
        
        echo "$OUTPUT"

        # Extract the metrics line from output
        METRICS_LINE=$(echo "$OUTPUT" | grep "METRICS_DATA:" | tail -n 1)

        if [ -n "$METRICS_LINE" ]; then
            THROUGHPUT=$(echo "$METRICS_LINE" | cut -d',' -f3)
            MATCHES=$(echo "$METRICS_LINE" | cut -d',' -f5)
            ELAPSED=$(echo "$METRICS_LINE" | cut -d',' -f7)
            
            echo "run_${run}_${queues}q,${queues},${THROUGHPUT},${ELAPSED},${MATCHES}" >> "${CSV_FILE}"
            echo "-> Run ${run} (${queues}q) : ${THROUGHPUT} Gbps"
        else
            echo "Warning: Metrics not found for ${queues} queues (Run ${run})"
        fi

        sleep 1
    done
done

echo "=========================================================="
echo "All In-Memory benchmarks (${NUM_RUNS} runs each) are finished!"
echo "CSV file generated: ${CSV_FILE}"
echo "=========================================================="