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
echo "Mode,Param_Value,Block_Size,Grid_Size,Time_s,Throughput_Gbps,Total_Matches,Data_MB,Pattern_Count" > "$OUTPUT_FILE"

# --- Fonction de mesure ---
run_and_average() {
    local m=$1; local p=$2; local b=$3; local g=$4
    local sum_time=0
    local final_matches=0

    echo -n "🚀 Testing $m (P:$p, B:$b)... "

    for (( i=1; i<=$ITERATIONS; i++ )); do
        # Exécution : ./nids_gpu <mode> <threads/param> <loops> <rules> <pcap> <block_size>
        res=$($TARGET "$m" "$p" 1 "$PATTERNS" "$DATA" "$b")
        
        # Extraction propre avec awk
        t=$(echo "$res" | grep "Time Elapsed" | awk -F': ' '{print $2}' | tr -d 's' | xargs)
        m_count=$(echo "$res" | grep "Total Matches" | awk -F': ' '{print $2}' | xargs)

        # Sécurité si le programme crash ou ne renvoie rien
        if [ -z "$t" ]; then
            echo -e "\n❌ ERREUR fatale sur $m. Sortie : $res"
            exit 1
        fi

        sum_time=$(echo "$sum_time + $t" | bc -l)
        final_matches=$m_count
    done

    # Calcul de la moyenne temporelle
    avg_time=$(echo "scale=6; $sum_time / $ITERATIONS" | bc -l)
    
    # Calcul du débit moyen en Gbps
    avg_tp=$(echo "scale=2; ($FILE_SIZE_BYTES * 8) / ($avg_time * 1000000000)" | bc -l)

    # Sauvegarde dans le CSV
    echo "$m,$p,$b,$g,$avg_time,$avg_tp,$final_matches,$FILE_SIZE_MB,$PATTERN_COUNT" >> "$OUTPUT_FILE"
    echo "Moyenne: $avg_tp Gbps"
}

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
BLOCK_SIZES="32 64 128 256 512 1024 2048"
BATCH_SIZES="512 1024 2048 4096 16384 65536 131072 262144"

for b in $BLOCK_SIZES; do
    echo -e "\n--- Testing Block Size: $b ---"
    for bs in $BATCH_SIZES; do
        # On affiche les paramètres en cours pour suivre l'avancement
        echo -n "  -> Batch: $bs pkts | "
        
        # Appel : ./nids_gpu <mode> <param> <loops> <rules> <pcap> <block_size> <batch_size>
        run_and_average "gpu_async" "1" "$b" "$bs"
    done
done

echo -e "\n=================================================="
echo "✅ TERMINÉ ! Résultats sauvegardés dans : $OUTPUT_FILE"
echo "=================================================="