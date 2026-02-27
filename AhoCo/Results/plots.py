import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import numpy as np

# Configuration pour un style "Académique" (propre, lisible en noir et blanc ou couleur)
plt.style.use('seaborn-v0_8-whitegrid')
plt.rcParams.update({'font.size': 12, 'font.family': 'sans-serif'})

def generate_graphs(csv_file):
    print(f"📊 Chargement des données depuis {csv_file}...")
    
    # Lecture du CSV
    try:
        df = pd.read_csv(csv_file)
    except FileNotFoundError:
        print(f"❌ Erreur: Le fichier {csv_file} est introuvable. Lance d'abord le script Bash !")
        return

    # Nettoyage des données
    # On convertit les colonnes en numériques (en forçant les 'N/A' en NaN)
    df['CPU_Threads'] = pd.to_numeric(df['CPU_Threads'], errors='coerce')
    df['GPU_ThreadsPerBlock'] = pd.to_numeric(df['GPU_ThreadsPerBlock'], errors='coerce')
    df['GPU_Blocks'] = pd.to_numeric(df['GPU_Blocks'], errors='coerce')
    
    # Conversion du Throughput de Mbps vers Gbps (plus lisible pour des gros scores)
    df['Throughput_Gbps'] = df['Throughput_Mbps'] / 1000.0

    # ==========================================
    # GRAPHIQUE 1 : CPU SCALING (Courbe)
    # ==========================================
    df_cpu = df[df['Mode'] == 'cpu'].sort_values(by='CPU_Threads')
    
    if not df_cpu.empty:
        plt.figure(figsize=(8, 5))
        plt.plot(df_cpu['CPU_Threads'], df_cpu['Throughput_Gbps'], 
                 marker='o', linewidth=2, markersize=8, color='#1f77b4')
        
        plt.title('Performance du NIDS sur CPU (OpenMP)', fontsize=14, fontweight='bold')
        plt.xlabel('Nombre de Threads', fontsize=12)
        plt.ylabel('Débit (Gbps)', fontsize=12)
        
        # Forcer l'axe X à n'afficher que des entiers
        plt.xticks(df_cpu['CPU_Threads']) 
        plt.ylim(bottom=0) # Toujours commencer l'axe Y à 0 pour être honnête
        
        plt.tight_layout()
        plt.savefig('cpu_scaling_plot.png', dpi=300) # dpi=300 pour la haute qualité
        print("✅ Graphique CPU généré : cpu_scaling_plot.png")
        plt.close()

    # ==========================================
    # GRAPHIQUE 2 : GPU HEATMAP (Carte de chaleur)
    # ==========================================
    df_gpu = df[df['Mode'] == 'gpu']
    
    if not df_gpu.empty:
        # On crée une matrice 2D (Lignes = Threads, Colonnes = Blocs)
        pivot_gpu = df_gpu.pivot(index="GPU_ThreadsPerBlock", 
                                 columns="GPU_Blocks", 
                                 values="Throughput_Gbps")
        
        plt.figure(figsize=(9, 6))
        # Utilisation de Seaborn pour une belle Heatmap
        sns.heatmap(pivot_gpu, annot=True, fmt=".1f", cmap="YlOrRd", 
                    cbar_kws={'label': 'Débit (Gbps)'}, linewidths=.5)
        
        plt.title('Grid Search GPU CUDA (Débit en Gbps)', fontsize=14, fontweight='bold')
        plt.xlabel('Nombre de Blocs', fontsize=12)
        plt.ylabel('Threads par Bloc', fontsize=12)
        
        # Inverser l'axe Y pour avoir les petites valeurs en bas
        plt.gca().invert_yaxis()
        
        plt.tight_layout()
        plt.savefig('gpu_heatmap_plot.png', dpi=300)
        print("✅ Graphique GPU généré : gpu_heatmap_plot.png")
        plt.close()

if __name__ == "__main__":
    generate_graphs("benchmark_results.csv")