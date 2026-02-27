#!/bin/bash

# Fichier de sortie
OUTPUT_FILE="benchmark_results.csv"

# On écrit l'en-tête du fichier CSV
echo "Mode,CPU_Threads,GPU_ThreadsPerBlock,GPU_Blocks,Time_s,Throughput_Mbps" > $OUTPUT_FILE

echo "======================================"
echo "🚀 DÉBUT DE LA CAMPAGNE DE BENCHMARK 🚀"
echo "======================================"

# ---------------------------------------------------------
# 1. BENCHMARK CPU (De 1 à 12 threads)
# ---------------------------------------------------------
echo -e "\n--- Lancement des tests CPU ---"
for cpu_t in 1 2 4 6 8 10 12; do
    echo -n "Test CPU avec $cpu_t threads... "
    
    # On exécute le programme et on capture la sortie
    result=$(./framework_nids cpu $cpu_t 1 Rules/patterns.txt Data/data.bin)
    
    # On extrait le temps et le débit avec 'awk'
    time=$(echo "$result" | grep "Time elapsed" | awk '{print $4}')
    throughput=$(echo "$result" | grep "Throughput" | awk '{print $3}')
    
    # On sauvegarde dans le CSV
    echo "cpu,$cpu_t,N/A,N/A,$time,$throughput" >> $OUTPUT_FILE
    echo "Fait ($throughput Mbps)"
done

# ---------------------------------------------------------
# 2. BENCHMARK GPU (Grid Search)
# ---------------------------------------------------------
echo -e "\n--- Lancement des tests GPU ---"
# Test des tailles de blocs (multiples de 32 pour les Warps CUDA)
for gpu_t in 64 128 256 512 1024; do
    # Test du nombre total de blocs envoyés à la grille
    for gpu_b in 256 512 1024 2048 4096 8192; do
        echo -n "Test GPU (Threads/Bloc: $gpu_t | Blocs: $gpu_b)... "
        
        result=$(./framework_nids gpu 1 1 Rules/patterns.txt Data/data.bin $gpu_t $gpu_b)
        
        time=$(echo "$result" | grep "Time elapsed" | awk '{print $4}')
        throughput=$(echo "$result" | grep "Throughput" | awk '{print $3}')
        
        echo "gpu,N/A,$gpu_t,$gpu_b,$time,$throughput" >> $OUTPUT_FILE
        echo "Fait ($throughput Mbps)"
    done
done

echo -e "\n✅ Benchmark terminé ! Résultats sauvegardés dans $OUTPUT_FILE"