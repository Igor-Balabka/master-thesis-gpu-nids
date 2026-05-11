#!/bin/bash
# --- Configuration ---
OUTPUT_FILE="benchmark_results.csv"
PATTERNS="Rules/patterns.txt"
DATA="Pcap/MixFile.pcap"
ITERATIONS=5
TARGET="./nids_gpu"
NCU_PATH="/usr/local/cuda/bin/ncu"

# --- File info ---
FILE_SIZE_BYTES=$(stat -c%s "$DATA")
FILE_SIZE_MB=$(echo "scale=2; $FILE_SIZE_BYTES / 1024 / 1024" | bc)
PATTERN_COUNT=$(grep -cve '^\s*$' "$PATTERNS")

# --- Confirmed CC 8.6 metric names ---
METRICS="l1tex__t_sector_pipe_lsu_mem_global_op_ld_hit_rate"
METRICS+=",lts__t_sector_op_read_hit_rate"
METRICS+=",dram__throughput.avg.pct_of_peak_sustained_elapsed"

# CSV Header

extract_ratio_metric() {
    local csv="$1"
    local metric_name="$2"
    echo "$csv" | grep "\"${metric_name}.pct\"" | awk -F',' '{
        val = $NF
        gsub(/["\r\n\t ]/, "", val)
        print val
    }' | head -n 1
}

extract_throughput_metric() {
    local csv="$1"
    local metric_name="$2"
    echo "$csv" | grep "\"${metric_name}\"" | awk -F',' '{
        val = $NF
        gsub(/["\r\n\t ]/, "", val)
        print val
    }' | head -n 1
}

run_and_average() {
    local mode=$1 slots=$2 block=$3 batch=$4
    local sum_time=0 final_matches=0
    local LOOPS=1

    echo -n "🚀 Testing $mode (S:$slots, B:$block, Batch:$batch)... "

    # STEP 1: Real throughput
    for (( i=1; i<=ITERATIONS; i++ )); do
        res=$("$TARGET" "$mode" "$slots" "$LOOPS" "$PATTERNS" "$DATA" "$block" "$batch" "$slots")        
        t=$(echo "$res" | grep "Time Elapsed" | awk -F': ' '{print $2}' | tr -d 's ')
        final_matches=$(echo "$res" | grep "Total Matches" | awk -F': ' '{print $2}' | tr -d ' ')
        [ -z "$t" ] && t=0
        sum_time=$(echo "$sum_time + $t" | bc -l)
    done

    avg_time=$(echo "scale=6; $sum_time / $ITERATIONS" | bc -l)
    
    if (( $(echo "$avg_time <= 0.000000" | bc -l) )); then
        avg_time="0.000001"
    fi
    avg_tp=$(echo "scale=2; ($FILE_SIZE_BYTES * 8 * $LOOPS) / ($avg_time * 1000000000)" | bc -l)
    # STEP 2: Hardware profiling
    if [ "$mode" == "cpu" ]; then
        echo -n "📊 No GPU profiling for CPU... "
        l1_hit=0; l1_miss=0; l2_hit=0; l2_miss=0; mem_bus=0
    else
        echo -n "📊 Profiling... "
        raw_ncu=$(sudo "$NCU_PATH" \
            --metrics "$METRICS" \
            --replay-mode kernel \
            --launch-skip 2 \
            --launch-count 1 \
            --csv \
            "$TARGET" "$mode" "$slots" 2 "$PATTERNS" "$DATA" "$block" "$batch" "$slots" 2>/dev/null)

        kernel_lines=$(echo "$raw_ncu" | grep -E "ac_buffering_kernel|ac_classic_kernel")

        if [ -n "$kernel_lines" ]; then
            l1_hit=$(extract_ratio_metric      "$kernel_lines" "l1tex__t_sector_pipe_lsu_mem_global_op_ld_hit_rate")
            l2_hit=$(extract_ratio_metric      "$kernel_lines" "lts__t_sector_op_read_hit_rate")
            mem_bus=$(extract_throughput_metric "$kernel_lines" "dram__throughput.avg.pct_of_peak_sustained_elapsed")

            l1_hit=${l1_hit:-0}
            l2_hit=${l2_hit:-0}
            mem_bus=${mem_bus:-0}

            l1_miss=$(echo "scale=2; 100 - $l1_hit" | bc -l)
            l2_miss=$(echo "scale=2; 100 - $l2_hit" | bc -l)
        else
            l1_hit=0; l1_miss=100; l2_hit=0; l2_miss=100; mem_bus=0
            echo -n "⚠️  No kernel data found "
        fi
    fi

    # STEP 3: Write CSV row
    echo "$mode,$slots,$block,$batch,$avg_time,$avg_tp,$final_matches,$FILE_SIZE_MB,$PATTERN_COUNT,$l1_hit,$l1_miss,$l2_hit,$l2_miss,$mem_bus" >> "$OUTPUT_FILE"
    echo "✅ $avg_tp Gbps | L1: ${l1_hit}% hit | L2: ${l2_hit}% hit | DRAM: ${mem_bus}%"
}

echo "=================================================="
echo "   🔬 COMPARATIVE BENCHMARK"
echo "=================================================="


# # --- 1. BENCHMARK CPU (Multi-threading OpenMP) ---
# echo -e "\n[SECTION 1/3] Benchmarking CPU (OpenMP)..."
# for t in 1 2 4 8 12; do
#     run_and_average "cpu" "$t" "1" "1"
# done

# # --- 2. BENCHMARK GPU SYNC (Classic Kernel) ---
# echo -e "\n[SECTION 2/3] Benchmarking GPU Sync (Standard)..."
# for b in 32 64 128 256 512 1024; do
#     run_and_average "gpu" "1" "$b" "1024"
# done


# --- 3. BENCHMARK GPU ASYNC ---
echo -e "\n[SECTION 3/3] Benchmarking GPU ASync..."

# BUFFER="2 3 4 5 6 7 8"
# BLOCK_SIZES="4 8 16 32 64 128 256 512 1024 2048"
# BATCH_SIZES="128 256 512 1024 2048 4096 16384 65536 131072 262144"


BUFFER="6 7 8"
BLOCK_SIZES="4 8 16 32 64 128 256 512 1024"
BATCH_SIZES="128 256 512 1024 2048 4096 16384 65536 131072 262144"

for s in $BUFFER; do
    echo -e "\n>>> Testing with $s buffers (Slots) <<<"
    for b in $BLOCK_SIZES; do
        echo -e "\n--- Block Size: $b ---"
        for bs in $BATCH_SIZES; do
            run_and_average "gpu_async" "$s" "$b" "$bs"
        done
    done
done