#!/bin/bash

# --- Configuration ---
OUTPUT_FILE="benchmark_results.csv"
PATTERNS="Rules/patterns.txt"
DATA="Pcap/MixFile.pcap" 
ITERATIONS=5               
TARGET="./nids_gpu"        
NCU_PATH="/usr/local/cuda/bin/ncu" # Chemin complet vers NCU

# --- Infos fichiers ---
FILE_SIZE_BYTES=$(stat -c%s "$DATA")
FILE_SIZE_MB=$(echo "scale=2; $FILE_SIZE_BYTES / 1024 / 1024" | bc)
PATTERN_COUNT=$(grep -cve '^\s*$' "$PATTERNS")

# Header du CSV
echo "Mode,Slots,Block_Size,Batch_Size,Time_s,Throughput_Gbps,Matches,Data_MB,Patterns,L1_Hit,L1_Miss,L2_Hit,L2_Miss,Mem_Bus_Util,Occupancy" > "$OUTPUT_FILE"

# --- Fonction de mesure ---
run_and_average() {
    local m=$1; local s=$2; local b=$3; local bs=$4
    local sum_time=0
    local final_matches=0

    echo -n "🚀 Testing $m (S:$s, B:$b, Batch:$bs)... "

    # --- ÉTAPE 1 : MESURE DE LA VITESSE RÉELLE ---
    for (( i=1; i<=$ITERATIONS; i++ )); do
        res=$($TARGET "$m" "1" 1 "$PATTERNS" "$DATA" "$b" "$bs" "$s")
        t=$(echo "$res" | grep "Time Elapsed" | awk -F': ' '{print $2}' | tr -d 's' | xargs)
        m_count=$(echo "$res" | grep "Total Matches" | awk -F': ' '{print $2}' | xargs)

        if [ -z "$t" ]; then t=0; fi
        sum_time=$(echo "$sum_time + $t" | bc -l)
        final_matches=$m_count
    done

    # --- ÉTAPE 2 : PROFILAGE MATÉRIEL (NCU) ---
    # Stratégie : On force 100 loops uniquement pour NCU pour stabiliser les capteurs
    # On utilise --launch-count 1 pour ne pas saturer le profiler avec l'async
    echo -n "📊 Profiling... "
    
    raw_output=$($NCU_PATH --metrics l1tex__t_sectors_pipe_lsu_mem_global_op_ld_hit_rate,l2_cache_hit_rate,dram__throughput.avg.pct_of_peak_sustained_elapsed,launch__occupancy_per_shared_multiproc \
        --launch-skip 5 --launch-count 1 --csv --page raw \
        "$TARGET" "$m" "1" 100 "$PATTERNS" "$DATA" "$b" "$bs" "$s" 2>/dev/null)
    
    cache_data=$(echo "$raw_output" | grep "ac_buffering_kernel" | head -n 1)

    if [[ "$cache_data" == *","* ]]; then
        # NCU trie souvent par ordre alphabétique dans le CSV : dram, l1, l2, occupancy
        mem_bus=$(echo "$cache_data" | awk -F',' '{print $(NF-3)}' | tr -d '"%')
        l1_hit=$(echo "$cache_data" | awk -F',' '{print $(NF-2)}' | tr -d '"%')
        l2_hit=$(echo "$cache_data" | awk -F',' '{print $(NF-1)}' | tr -d '"%')
        occupancy=$(echo "$cache_data" | awk -F',' '{print $NF}' | tr -d '"%')
    else
        l1_hit=0; l2_hit=0; mem_bus=0; occupancy=0
        echo -n "⚠️ Skip "
    fi

    l1_miss=$(echo "100 - $l1_hit" | bc -l)
    l2_miss=$(echo "100 - $l2_hit" | bc -l)

    # --- ÉTAPE 3 : CALCULS ET SAUVEGARDE ---
    avg_time=$(echo "scale=6; $sum_time / $ITERATIONS" | bc -l)
    avg_tp=$(echo "scale=2; ($FILE_SIZE_BYTES * 8) / ($avg_time * 1000000000)" | bc -l)

    echo "$m,$s,$b,$bs,$avg_time,$avg_tp,$final_matches,$FILE_SIZE_MB,$PATTERN_COUNT,$l1_hit,$l1_miss,$l2_hit,$l2_miss,$mem_bus,$occupancy" >> "$OUTPUT_FILE"
    echo "Done: $avg_tp Gbps | L2 Miss: $l2_miss%"
}

echo "=================================================="
echo "   🔬 DÉBUT DU BENCHMARK COMPARATIF"
echo "=================================================="

echo -e "\n[SECTION 3/3] Benchmarking GPU Async (Streams)..."
BUFFER="2 3 4 5 6 7 8"
BLOCK_SIZES="4 8 16 32 64 128 256 512 1024 2048"
BATCH_SIZES="128 256 512 1024 2048 4096 16384 65536 131072 262144"
for s in $BUFFER; do
    echo -e "\n>>> Testing with $s buffers (Slots) <<<"
    for b in $BLOCK_SIZES; do
        echo -e "\n--- Testing Block Size: $b ---"
        for bs in $BATCH_SIZES; do
            # On affiche les paramètres en cours pour suivre l'avancement
            echo -n "  -> Batch: $bs pkts | "
            
            # Appel : ./nids_gpu <mode> <param> <loops> <rules> <pcap> <block_size> <batch_size>
            run_and_average "gpu_async" "$s" "$b" "$bs"
        done
    done
done