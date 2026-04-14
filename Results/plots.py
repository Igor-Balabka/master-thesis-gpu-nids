import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import os
import matplotlib.ticker as ticker

# --- Academic Style Configuration ---
plt.rcParams.update({
    'font.size': 11,
    'axes.labelsize': 13,
    'axes.titlesize': 15,
    'xtick.labelsize': 11,
    'ytick.labelsize': 11,
    'legend.fontsize': 10,
    'figure.figsize': (12, 7),
    'axes.grid': False,      
    'svg.fonttype': 'none',
    'pdf.fonttype': 42,
    'figure.autolayout': True
})

def save_plot(name):
    """Saves in PNG, SVG, and PDF formats"""
    plt.savefig(f"{name}.png", dpi=300)
    plt.savefig(f"{name}.svg", format='svg')
    plt.savefig(f"{name}.pdf", format='pdf')
    print(f"✅ Files created: {name}.png, .svg, and .pdf")

def generate_all_plots(csv_file):
    if not os.path.exists(csv_file):
        print(f"❌ Error: {csv_file} not found.")
        return

    df = pd.read_csv(csv_file)
    df['Throughput_Gbps'] = pd.to_numeric(df['Throughput_Gbps'], errors='coerce')
    df['Grid_Size_Num'] = pd.to_numeric(df['Grid_Size'], errors='coerce')

    # --- PLOT 1: Peak Performance Comparison ---
    # --- PLOT 1: Peak Performance Comparison (Professional Style) ---
    plt.figure()
    
    idx = df.groupby('Mode')['Throughput_Gbps'].idxmax()
    best_df = df.loc[idx].sort_values('Throughput_Gbps')

    labels = []
    for _, row in best_df.iterrows():
        if row['Mode'] == 'cpu':
            labels.append(f"CPU\n({int(row['Param_Value'])} Threads)")
        elif row['Mode'] == 'gpu':
            labels.append(f"GPU Sync\n(B:{int(row['Block_Size'])})")
        else:
            labels.append(f"GPU Async\n(B:{int(row['Block_Size'])}, G:{int(row['Grid_Size_Num'])})")

    best_df['Custom_Label'] = labels
    
    # Utilisation de la palette 'deep' qui est plus sobre et professionnelle
    # edgecolors='0.2' ajoute une fine bordure gris foncé pour le relief
    ax = sns.barplot(
        data=best_df, 
        x='Custom_Label', 
        y='Throughput_Gbps', 
        hue='Custom_Label', 
        palette='deep', 
        legend=False,
        edgecolor='0.2',
        linewidth=1.5
    )
    
    plt.title('Peak Throughput Comparison', fontweight='bold', pad=20)
    plt.ylabel('Throughput (Gbps)')
    plt.xlabel('Execution Configuration')
    
    # Ajout d'une grille horizontale légère (Y-axis only)
    plt.grid(True, axis='y', linestyle='--', alpha=0.4, color='gray')
    
    # Annotations avec une police un peu plus discrète
    for p in ax.patches:
        ax.annotate(
            f'{p.get_height():.2f} Gbps', 
            (p.get_x() + p.get_width() / 2., p.get_height()),
            ha='center', va='bottom', 
            fontsize=11, fontweight='bold', 
            color='#333333',
            xytext=(0, 7), 
            textcoords='offset points'
        )
    
    # Supprimer les bordures inutiles du graphique (Top et Right)
    sns.despine()
    
    save_plot('01_Peak_Performance_Comparison')

    # --- PLOT 2: GPU Async Scalability (LOG2 SCALE - ENHANCED) ---
    plt.figure()
    # Ajout d'une grille plus fine pour le log
    plt.grid(True, which="both", linestyle='--', alpha=0.5)
    df_async = df[df['Mode'] == 'gpu_async'].sort_values('Grid_Size_Num')
    
    sns.lineplot(data=df_async, x='Grid_Size_Num', y='Throughput_Gbps', 
                 hue='Block_Size', marker='o', palette='bright', linewidth=2.5, markersize=8)
    
    # Configuration Log2 pour l'axe X
    plt.xscale('log', base=2)
    
    # Formater les labels de l'axe X pour afficher les nombres entiers au lieu de 2^n
    ax = plt.gca()
    ax.xaxis.set_major_formatter(ticker.ScalarFormatter())
    
    # Définir manuellement les ticks pour qu'ils soient lisibles (puissances de 2)
    unique_batches = sorted(df_async['Grid_Size_Num'].unique())
    plt.xticks(unique_batches, [int(x) for x in unique_batches], rotation=45)
    
    plt.title('GPU Async Performance: Throughput Scalability vs. Batch Size', fontweight='bold')
    plt.xlabel('Batch Size (Number of packets)')
    plt.ylabel('Throughput (Gbps)')
    plt.legend(title='Threads per Block', bbox_to_anchor=(1.05, 1), loc='upper left', frameon=True)
    save_plot('02_GPU_Async_Scalability_Log2')

    # --- PLOT 3: Optimization Heatmap ---
    plt.figure(figsize=(10, 8))
    pivot_async = df_async.pivot_table(index='Block_Size', columns='Grid_Size_Num', values='Throughput_Gbps')
    sns.heatmap(pivot_async, annot=True, fmt=".2f", cmap="YlGnBu", cbar_kws={'label': 'Throughput (Gbps)'}, linewidths=0) 
    plt.title('Optimization Matrix: Block Size & Batch Size Efficiency', fontweight='bold')
    plt.xlabel('Batch Size (Number of packets)')
    plt.ylabel('Block Size (Threads per Block)')
    save_plot('03_Optimization_Heatmap')

    # --- PLOT 4: CPU Multi-threading ---
    plt.figure(figsize=(8, 5))
    plt.grid(True, linestyle='--', alpha=0.7)
    df_cpu = df[df['Mode'] == 'cpu'].sort_values('Param_Value')
    plt.plot(df_cpu['Param_Value'], df_cpu['Throughput_Gbps'], color='tab:red', marker='D', linewidth=2)
    plt.title('CPU Multi-threading Scalability', fontweight='bold')
    plt.xlabel('Number of CPU Threads')
    plt.ylabel('Throughput (Gbps)')
    plt.xticks(df_cpu['Param_Value'].unique())
    save_plot('04_CPU_Scalability')

if __name__ == "__main__":
    generate_all_plots("benchmark_results.csv")