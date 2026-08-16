#!/usr/bin/env bash

RESULTS_DIR="csv_results/5_6_Rules"
CSV_FILE="${RESULTS_DIR}/nids_comparison_ruleset_scaling.csv"

mkdir -p "${RESULTS_DIR}"

make clean
make

echo "Mode,Run,Nbr_Pattern,Througput,NB_Matches,Memory_MB" > "${CSV_FILE}"

NUM_RUNS=5

for mode in cpu; do
    for rules_file in $(ls Rules/Splitted/patterns_*.txt | sort -V); do
        nbr_patterns=$(basename "${rules_file}" | sed 's/patterns_//;s/\.txt//')
        
        if [ "$mode" == "gpu" ]; then
            EAL_ARGS="-l 0,1,2"
            APP_ARGS="--mode gpu --in-memory --rx-queues 1"
        else
            EAL_ARGS="-l 0,1,2,3,4 --vdev=net_pcap0,rx_pcap=Pcap/MixFile.pcap"
            APP_ARGS="--mode cpu"
        fi

        OUTPUT_FIRST=$(sudo ./pipeline_nids $EAL_ARGS -- $APP_ARGS "${rules_file}" 2>&1)
        
        if [ "$mode" == "gpu" ]; then
            STATS_LINE=$(echo "$OUTPUT_FIRST" | grep "\[GPU DFA Stats\]" | tail -n 1)
            mem_val=$(echo "$STATS_LINE" | sed 's/.*Total VRAM: \([0-9.]*\) MB.*/\1/')
        else
            STATS_LINE=$(echo "$OUTPUT_FIRST" | grep "\[CPU DFA Stats\]" | tail -n 1)
            mem_val=$(echo "$STATS_LINE" | sed 's/.*Total RAM: \([0-9.]*\) MB.*/\1/')
        fi
        if [ -z "$mem_val" ]; then mem_val="0.00"; fi

        for run in $(seq 1 ${NUM_RUNS}); do
            sudo rm -rf /var/run/dpdk/rte/* 2>/dev/null
            sleep 1

            if [ "$run" -eq 1 ]; then
                OUTPUT="$OUTPUT_FIRST"
            else
                OUTPUT=$(sudo ./pipeline_nids $EAL_ARGS -- $APP_ARGS "${rules_file}" 2>&1)
            fi
            
            METRICS_LINE=$(echo "$OUTPUT" | grep "METRICS_DATA:" | tail -n 1)

            if [ -n "$METRICS_LINE" ]; then
                clean_metrics=$(echo "$METRICS_LINE" | sed 's/METRICS_DATA://')
                throughput=$(echo "$clean_metrics" | awk -F',' '{print $3}')
                matches=$(echo "$clean_metrics" | awk -F',' '{print $5}')
                
                echo "${mode^^},${run},${nbr_patterns},${throughput},${matches},${mem_val}" >> "${CSV_FILE}"
                echo "  -> [${mode^^}] Run ${run}/${NUM_RUNS} : ${throughput} Gbps | Matches : ${matches} | Memory : ${mem_val} MB"
            else
                echo "Warning: Metrics not found for ${nbr_patterns} patterns (Mode: ${mode}, Run ${run})"
            fi

            sleep 1
        done
    done
done

echo "Benchmark finished successfully! CSV file: ${CSV_FILE}"