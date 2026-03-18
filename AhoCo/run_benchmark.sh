#!/bin/bash

# Configuration
OUTPUT_FILE="benchmark_results.csv"
PATTERNS="./Rules/patterns.txt"
DATA="./Data/data.bin"
ITERATIONS=5  # Nombre de passages pour la moyenne

# Infos fichiers
FILE_SIZE_BYTES=$(stat -c%s "$DATA")
FILE_SIZE_MB=$(echo "scale=2; $FILE_SIZE_BYTES / 1024 / 1024" | bc)
PATTERN_COUNT=$(grep -cve '^\s*$' "$PATTERNS")

echo "Mode,Param_Value,Block_Size,Grid_Size,Time_s,Throughput_Gbps,Total_Matches,Data_MB,Pattern_Count" > "$OUTPUT_FILE"

echo "=================================================="
echo "      🔬 SCIENTIFIC BENCHMARK (Average of $ITERATIONS)"
echo "=================================================="

# Fonction pour exécuter et moyenner
run_and_average() {
    local m=$1; local p=$2; local b=$3; local g=$4
    local sum_time=0
    local sum_tp=0
    local final_matches=0

    for (( i=1; i<=$ITERATIONS; i++ )); do
        # Exécution du programme
        res=$(./framework_nids $m $p 1 $PATTERNS $DATA $b $g)
        
        # Extraction des valeurs
        t=$(echo "$res" | grep "Time Elapsed" | awk '{print $4}')
        tp=$(echo "$res" | grep "Throughput" | awk '{print $3}')
        final_matches=$(echo "$res" | grep "Total Matches" | awk '{print $4}')
        
        # Somme pour la moyenne
        sum_time=$(echo "$sum_time + $t" | bc -l)
        sum_tp=$(echo "$sum_tp + $tp" | bc -l)
    done

    # Calcul des moyennes
    avg_time=$(echo "scale=4; $sum_time / $ITERATIONS" | bc -l)
    avg_tp=$(echo "scale=2; $sum_tp / $ITERATIONS" | bc -l)

    # Écriture dans le CSV
    echo "$m,$p,$b,$g,$avg_time,$avg_tp,$final_matches,$FILE_SIZE_MB,$PATTERN_COUNT" >> "$OUTPUT_FILE"
    echo "   -> Average: $avg_tp Gbps"
}

# 1. CPU
echo -e "\n[1/3] Testing CPU..."
for t in 1 4 12; do
    echo -n "Testing CPU $t threads..."
    run_and_average "cpu" "$t" "N/A" "N/A"
done

# 2. GPU SYNC
echo -e "\n[2/3] Testing GPU Sync..."
for b in 128 256 512 1024; do
    for g in 256 1024 4096; do
        echo -n "Testing GPU Sync (B:$b G:$g)..."
        run_and_average "gpu" "1" "$b" "$g"
    done
done

# 3. GPU ASYNC
echo -e "\n[3/3] Testing GPU Async..."
for b in 128 256 512 1024; do
    for g in 256 1024 4096; do
        echo -n "Testing GPU Async (B:$b G:$g)..."
        run_and_average "gpu_async" "1" "$b" "$g"
    done
done

echo -e "\n✅ DONE! Results averaged over $ITERATIONS runs."