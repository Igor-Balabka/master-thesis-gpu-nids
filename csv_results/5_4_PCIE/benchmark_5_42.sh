#!/usr/bin/env bash
set -e

# Configuration paths and files
TARGET_CPP="max_speed_pcie.cu"
TARGET_BIN="max_speed_pcie"
RESULTS_DIR="csv_results/5_4_PCIE"
CSV_FILE="${RESULTS_DIR}/max_speed_h2d_scaling.csv"

# Create output directory if it does not exist
mkdir -p "${RESULTS_DIR}"

echo "Compiling ${TARGET_CPP}..."
nvcc -O3 "${TARGET_CPP}" -o "${TARGET_BIN}"

# Initialize the CSV file header
echo "Run_X,NB_Streams,PAges_Througput,Pinned_Thourgput" > "${CSV_FILE}"

NUM_RUNS=5

echo "=========================================================="
echo "STARTING MAX SPEED H2D SCALING BENCHMARKS (${NUM_RUNS} Runs)"
echo "=========================================================="

# Run the benchmark multiple times to get stable results
for run in $(seq 1 ${NUM_RUNS}); do
    echo "----------------------------------------------------------"
    echo "RUN ${run} / ${NUM_RUNS}"
    echo "----------------------------------------------------------"
    
    # Run the compiled program and capture output
    OUTPUT=$(./${TARGET_BIN})
    
    # Extract lines starting with RESULT: and append formatted data to CSV
    echo "$OUTPUT" | grep "RESULT:" | while read -r line; do
        DATA=$(echo "$line" | sed 's/RESULT://')
        echo "run_${run},${DATA}"
        echo "run_${run},${DATA}" >> "${CSV_FILE}"
    done

    sleep 1
done

echo "=========================================================="
echo "Benchmark finished! CSV file generated: ${CSV_FILE}"
echo "=========================================================="