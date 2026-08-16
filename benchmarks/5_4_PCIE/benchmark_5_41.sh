#!/usr/bin/env bash
set -e

TARGET_CPP="gpu_pcie_streams_benchmark.cu"
TARGET_BIN="gpu_pcie_streams_benchmark"
PCAP_RAM="/dev/shm/MixFile.pcap"
RESULTS_DIR="csv_results/5_4_PCIE"
CSV_FILE="${RESULTS_DIR}/pageable_vs_pinned_scaling_results.csv"

mkdir -p "${RESULTS_DIR}"

if [ ! -f "${PCAP_RAM}" ]; then
    echo "Error: PCAP file not found in RAM (${PCAP_RAM})!"
    exit 1
fi

echo "Compiling ${TARGET_CPP}..."
nvcc -O3 "${TARGET_CPP}" -o "${TARGET_BIN}" -lpcap

# Initialize CSV file with required format
echo "Run_X,NB_Streams,PAges_Througput,Pinned_Thourgput" > "${CSV_FILE}"

NUM_RUNS=5

echo "=========================================================="
echo "STARTING PAGEABLE VS PINNED SCALING BENCHMARKS (${NUM_RUNS} Runs)"
echo "=========================================================="

for run in $(seq 1 ${NUM_RUNS}); do
    echo "----------------------------------------------------------"
    echo "RUN ${run} / ${NUM_RUNS}"
    echo "----------------------------------------------------------"
    
    OUTPUT=$(./${TARGET_BIN})
    
    # Extract lines containing "RESULT:"
    echo "$OUTPUT" | grep "RESULT:" | while read -r line; do
        # Remove the "RESULT:" prefix
        DATA=$(echo "$line" | sed 's/RESULT://')
        echo "run_${run},${DATA}"
        echo "run_${run},${DATA}" >> "${CSV_FILE}"
    done

    sleep 1
done

echo "=========================================================="
echo "Finished! CSV file generated: ${CSV_FILE}"
echo "=========================================================="