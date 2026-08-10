#!/usr/bin/env bash

# ==============================================================================# 
# Script for Section 5.2: CPU Multi-Core Scaling (1 to 12 Cores)
# ==============================================================================

set -e

TARGET_MAIN="./pipeline_nids"
PATTERNS_FILE="Rules/patterns.txt"
PCAP_SINGLE="/dev/shm/MixFile.pcap"
RESULTS_DIR="csv_results"
CSV_FILE="${RESULTS_DIR}/cpu_scaling_results.csv"
LOG_PREFIX="${RESULTS_DIR}/cpu_core"

mkdir -p "${RESULTS_DIR}"

if [ ! -f "${PCAP_SINGLE}" ]; then
    echo "⚠️  PCAP file not found in /dev/shm! Copying Pcap/MixFile.pcap to RAM..."
    sudo cp Pcap/MixFile.pcap /dev/shm/MixFile.pcap
fi

if [ ! -f "${TARGET_MAIN}" ]; then
    make clean && make all
fi

echo "cores,run,lcores_list,throughput_gbps,ac_matches,duration_sec" > "${CSV_FILE}"

get_lcores_str() {
    local num_cores=$1
    local lcores="0"
    for ((i=1; i<num_cores; i++)); do
        lcores="${lcores},${i}"
    done
    echo "${lcores}"
}

for cores in {1..12}; do
    LCORES=$(get_lcores_str ${cores})
    
    for run in {1..5}; do
        LOG_FILE="${LOG_PREFIX}_${cores}core_run${run}.log"

        sudo killall -9 pipeline_nids 2>/dev/null || true
        sudo rm -rf /var/run/dpdk/rte/ 2>/dev/null
        sleep 0.5

        sudo "${TARGET_MAIN}" \
            -l "${LCORES}" \
            --vdev="net_pcap0,rx_pcap=${PCAP_SINGLE}" \
            -- \
            --mode cpu \
            "${PATTERNS_FILE}" > "${LOG_FILE}" 2>&1 || true

        GBPS=$(grep -i "Effective Throughput" "${LOG_FILE}" | awk -F':' '{print $2}' | awk '{print $1}' || echo "0.0")
        MATCHES=$(grep -i "AC Matches" "${LOG_FILE}" | awk -F':' '{print $2}' | awk '{print $1}' || echo "0")
        TIME=$(grep -i "Execution Time" "${LOG_FILE}" | awk -F':' '{print $2}' | awk '{print $1}' || echo "0.0")

        echo "${cores},${run},\"${LCORES}\",${GBPS},${MATCHES},${TIME}" >> "${CSV_FILE}"

        sleep 1
    done
done