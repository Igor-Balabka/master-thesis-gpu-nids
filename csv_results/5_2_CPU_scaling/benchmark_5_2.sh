#!/usr/bin/env bash

# ==============================================================================# 
# Script for Section 5.2: CPU Scaling + Cache Misses + AMD DRAM Bandwidth
# ==============================================================================

set -e

TARGET_MAIN="./pipeline_nids"
PATTERNS_FILE="Rules/patterns.txt"
PCAP_DISK="Pcap/MixFile.pcap"
PCAP_RAM="/dev/shm/MixFile.pcap"
RESULTS_DIR="csv_results"
CSV_FILE="${RESULTS_DIR}/cpu_scaling_results.csv"
LOG_PREFIX="${RESULTS_DIR}/cpu_core"

# 1. Create logs directory
sudo mkdir -p "${RESULTS_DIR}"
sudo chmod 777 "${RESULTS_DIR}"

# 2. Copy PCAP file to RAM (/dev/shm)
if [ ! -f "${PCAP_RAM}" ]; then
    if [ -f "${PCAP_DISK}" ]; then
        echo "Copying ${PCAP_DISK} to RAM (/dev/shm)..."
        cp "${PCAP_DISK}" "${PCAP_RAM}"
    else
        echo "Error: Source PCAP file (${PCAP_DISK}) does not exist!"
        exit 1
    fi
else
    echo "PCAP file already loaded in RAM (${PCAP_RAM})."
fi

if [ ! -f "${TARGET_MAIN}" ]; then
    make clean && make all
fi

# 3. CSV header
echo "cores,run,lcores_list,throughput_gbps,ac_matches,duration_sec,l1d_miss_pct,l2_miss_pct,l3_miss_pct,dram_bw_gbps" > "${CSV_FILE}"

get_lcores_str() {
    local num_cores=$1
    local lcores="0"
    for ((i=1; i<num_cores; i++)); do
        lcores="${lcores},${i}"
    done
    echo "${lcores}"
}

# 4. Benchmark loop: 1 to 12 cores (5 runs per core)
for cores in {1..12}; do
    LCORES=$(get_lcores_str ${cores})
    
    for run in {1..5}; do
        LOG_FILE="${LOG_PREFIX}_${cores}core_run${run}.log"
        PERF_LOG="${LOG_PREFIX}_${cores}core_run${run}_perf.log"

        sudo killall -9 pipeline_nids 2>/dev/null || true
        sudo rm -rf /var/run/dpdk/rte/ 2>/dev/null
        sleep 0.5

        # Run DPDK wrapped in perf stat (Caches + AMD Data Fabric / RAM)
        sudo perf stat \
            -e L1-dcache-loads,L1-dcache-load-misses,r164,r160,cache-references,cache-misses \
            -o "${PERF_LOG}" \
            "${TARGET_MAIN}" \
                -l "${LCORES}" \
                --vdev="net_pcap0,rx_pcap=${PCAP_RAM}" \
                -- \
                --mode cpu \
                "${PATTERNS_FILE}" > "${LOG_FILE}" 2>&1 || true

        # Set read permissions on logs
        sudo chmod 666 "${PERF_LOG}" "${LOG_FILE}" 2>/dev/null || true

        # --- A. Extract DPDK application metrics ---
        GBPS=$(grep -i "Effective Throughput" "${LOG_FILE}" | awk -F':' '{print $2}' | awk '{print $1}' || echo "0.0")
        MATCHES=$(grep -i "AC Matches" "${LOG_FILE}" | awk -F':' '{print $2}' | awk '{print $1}' || echo "0")
        TIME=$(grep -i "Execution Time" "${LOG_FILE}" | awk -F':' '{print $2}' | awk '{print $1}' || echo "0.0")

        # --- B. Extract and calculate cache misses and RAM bandwidth ---
        if [ -f "${PERF_LOG}" ]; then
            # 1. L1 Data Cache
            L1_LOADS=$(grep "L1-dcache-loads" "${PERF_LOG}" | awk '{print $1}' | tr -d ',' || echo "0")
            L1_MISSES=$(grep "L1-dcache-load-misses" "${PERF_LOG}" | awk '{print $1}' | tr -d ',' || echo "0")
            
            # 2. L2 Cache (AMD raw counters r164 / r160)
            L2_REFS=$(grep "r164" "${PERF_LOG}" | awk '{print $1}' | tr -d ',' || echo "0")
            L2_MISSES=$(grep "r160" "${PERF_LOG}" | awk '{print $1}' | tr -d ',' || echo "0")

            # 3. L3 / LLC Cache
            L3_REFS=$(grep "cache-references" "${PERF_LOG}" | awk '{print $1}' | tr -d ',' || echo "0")
            L3_MISSES=$(grep "cache-misses" "${PERF_LOG}" | awk '{print $1}' | tr -d ',' || echo "0")

            # Miss percentages
            L1_PCT=$( [ "${L1_LOADS}" -gt 0 ] 2>/dev/null && awk "BEGIN {printf \"%.2f\", (${L1_MISSES}/${L1_LOADS})*100}" || echo "0.00" )
            L2_PCT=$( [ "${L2_REFS}" -gt 0 ] 2>/dev/null && awk "BEGIN {printf \"%.2f\", (${L2_MISSES}/${L2_REFS})*100}" || echo "0.00" )
            L3_PCT=$( [ "${L3_REFS}" -gt 0 ] 2>/dev/null && awk "BEGIN {printf \"%.2f\", (${L3_MISSES}/${L3_REFS})*100}" || echo "0.00" )

            # 4. Calculate DRAM Bandwidth
            # Each L3 miss generates a 64-byte cache line access to RAM
            if [ "${L3_MISSES}" -gt 0 ] 2>/dev/null && [ $(awk "BEGIN {print (${TIME} > 0)}") -eq 1 ]; then
                DRAM_BW=$(awk "BEGIN {printf \"%.2f\", ((${L3_MISSES} * 64) / (${TIME} * 1073741824))}")
            else
                DRAM_BW="0.00"
            fi
        else
            L1_PCT="0.00"; L2_PCT="0.00"; L3_PCT="0.00"; DRAM_BW="0.00"
        fi

        # Write consolidated row to CSV
        echo "${cores},${run},\"${LCORES}\",${GBPS},${MATCHES},${TIME},${L1_PCT},${L2_PCT},${L3_PCT},${DRAM_BW}" >> "${CSV_FILE}"

        sleep 1
    done
done

echo "Benchmark finished successfully! All logs and CSV saved in ${RESULTS_DIR}/"