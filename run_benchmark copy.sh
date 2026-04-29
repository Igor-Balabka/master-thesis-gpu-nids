#!/bin/bash

# --- Configuration ---
OUTPUT_FILE="benchmark_results.csv"
PATTERNS="Rules/patterns.txt"
DATA="Pcap/MixFile.pcap" 
ITERATIONS=5               # 5 passages pour une moyenne scientifique solide
TARGET="./nids_gpu"        

# --- Vérifications ---
if [ ! -f "$TARGET" ]; then
    echo "❌ Erreur : L'exécutable $TARGET est introuvable. Fais 'make' d'abord."
    exit 1
fi

if [ ! -f "$DATA" ]; then
    echo "❌ Erreur : Le fichier PCAP $DATA est introuvable."
    exit 1
fi

# --- Infos fichiers ---
FILE_SIZE_BYTES=$(stat -c%s "$DATA")
FILE_SIZE_MB=$(echo "scale=2; $FILE_SIZE_BYTES / 1024 / 1024" | bc)
PATTERN_COUNT=$(grep -cve '^\s*$' "$PATTERNS")

# Header du CSV (ajusté pour tes colonnes)
echo "Mode,Slots,Block_Size,Batch_Size,Time_s,Throughput_Gbps,Matches,Data_MB,Patterns,L1_Hit,L1_MISS,L2_Hit_Rate,L2_Miss_Rate" > "$OUTPUT_FILE"

# --- Fonction de mesure ---
#!/bin/bash

# --- Configuration ---
OUTPUT_FILE="benchmark_results.csv"
PATTERNS="Rules/patterns.txt"
DATA="Pcap/MixFile.pcap" 
ITERATIONS=5               
TARGET="./nids_gpu"        

# --- Infos fichiers ---
FILE_SIZE_BYTES=$(stat -c%s "$DATA")
FILE_SIZE_MB=$(echo "scale=2; $FILE_SIZE_BYTES / 1024 / 1024" | bc)
PATTERN_COUNT=$(grep -cve '^\s*$' "$PATTERNS")

# Header du CSV (bien aligné avec l'ordre d'écriture)
echo "Mode,Slots,Block_Size,Batch_Size,Time_s,Throughput_Gbps,Matches,Data_MB,Patterns,L1_Hit,L1_Miss,L2_Hit,L2_Miss,Mem_Bus_Util,Occupancy" > "$OUTPUT_FILE"
# --- Fonction de mesure ---
run_and_average() {
    local m=$1; local s=$2; local b=$3; local bs=$4
    local sum_time=0
    local final_matches=0

    echo -n "🚀 Testing $m (S:$s, B:$b, Batch:$bs)... "

    for (( i=1; i<=$ITERATIONS; i++ )); do
        # Exécution normale pour le temps (1 loop pour le bench)
        res=$($TARGET "$m" "1" 1 "$PATTERNS" "$DATA" "$b" "$bs" "$s")
        
        t=$(echo "$res" | grep "Time Elapsed" | awk -F': ' '{print $2}' | tr -d 's' | xargs)
        m_count=$(echo "$res" | grep "Total Matches" | awk -F': ' '{print $2}' | xargs)

        sum_time=$(echo "$sum_time + $t" | bc -l)
        final_matches=$m_count

        # --- Profilage des caches (uniquement à la dernière itération) ---
        if [ $i -eq $ITERATIONS ]; then
    # On capture la sortie brute
            raw_output=$(/usr/local/cuda/bin/ncu --metrics l1tex__t_sectors_pipe_lsu_mem_global_op_ld_hit_rate,l2_cache_hit_rate,dram__throughput.avg.pct_of_peak_sustained_elapsed,launch__occupancy_per_shared_multiproc --csv --page raw "$TARGET" "$m" "1" 1 "$PATTERNS" "$DATA" "$b" "$bs" "$s")
            
            # On vérifie si le kernel est bien présent dans la sortie
            cache_data=$(echo "$raw_output" | grep "ac_buffering_kernel" | head -n 1)

            if [ -n "$cache_data" ]; then
                l1_hit=$(echo "$cache_data" | awk -F',' '{print $(NF-3)}' | tr -d '"%')
                l2_hit=$(echo "$cache_data" | awk -F',' '{print $(NF-2)}' | tr -d '"%')
                mem_bus=$(echo "$cache_data" | awk -F',' '{print $(NF-1)}' | tr -d '"%')
                occupancy=$(echo "$cache_data" | awk -F',' '{print $NF}' | tr -d '"%')
            else
                # Si NCU échoue, on met des 0 pour ne pas casser le CSV
                l1_hit=0; l2_hit=0; mem_bus=0; occupancy=0
                echo -n "⚠️ Profiling failed (too fast?) | "
            fi

            l1_miss=$(echo "100 - $l1_hit" | bc -l)
            l2_miss=$(echo "100 - $l2_hit" | bc -l)
        fi
    done

    avg_time=$(echo "scale=6; $sum_time / $ITERATIONS" | bc -l)
    avg_tp=$(echo "scale=2; ($FILE_SIZE_BYTES * 8) / ($avg_time * 1000000000)" | bc -l)

    # Sauvegarde dans le CSV (L'ordre doit correspondre au Header !)
    echo "$m,$s,$b,$bs,$avg_time,$avg_tp,$final_matches,$FILE_SIZE_MB,$PATTERN_COUNT,$l1_hit,$l1_miss,$l2_hit,$l2_miss,$mem_bus,$occupancy" >> "$OUTPUT_FILE"
    echo "Moyenne: $avg_tp Gbps | L2 Miss: $l2_miss% | Bus Util: $mem_bus% | Occupancy: $occupancy%"
}

# ... (reste du script identique pour les boucles for) ...

echo "=================================================="
echo "   🔬 DÉBUT DU BENCHMARK COMPARATIF"
echo "=================================================="
echo "Fichier : $DATA ($FILE_SIZE_MB MB)"
echo "Règles  : $PATTERN_COUNT patterns"
echo "=================================================="

# # --- 1. BENCHMARK CPU (Multi-threading OpenMP) ---
# echo -e "\n[SECTION 1/3] Benchmarking CPU (OpenMP)..."
# for t in 1 2 4 8 12; do
#     # Ici, on passe 't' (threads) comme paramètre de valeur
#     # On peut mettre "1" pour block_size car le CPU n'en a pas
#     run_and_average "cpu" "$t" "$t" "N/A"
# done

# # --- 2. BENCHMARK GPU SYNC (Classic Kernel) ---
# echo -e "\n[SECTION 2/3] Benchmarking GPU Sync (Standard)..."
# for b in 32 64 128 256 512 1024; do
#     # On passe "1" pour p (param) et 'b' pour block_size
#     run_and_average "gpu" "1" "$b" "1024"
# done

# --- 3. BENCHMARK GPU ASYNC (Double Buffering / Streams) ---
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

echo -e "\n=================================================="
echo "✅ TERMINÉ ! Résultats sauvegardés dans : $OUTPUT_FILE"
echo "=================================================="