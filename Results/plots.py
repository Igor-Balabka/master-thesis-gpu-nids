import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import os
import matplotlib.ticker as ticker

# --- Configuration Style Académique ---
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
    """Sauvegarde sans double extension"""
    base_name = os.path.splitext(name)[0]
    plt.savefig(f"{base_name}.png", dpi=300)
    plt.savefig(f"{base_name}.svg", format='svg')
    plt.savefig(f"{base_name}.pdf", format='pdf')
    print(f"✅ Files created: {base_name}.png, .svg, and .pdf")
    plt.close()

def generate_all_plots(csv_file):
    if not os.path.exists(csv_file):
        print(f"❌ Error: {csv_file} not found.")
        return

    df = pd.read_csv(csv_file)
    df['Throughput_Gbps'] = pd.to_numeric(df['Throughput_Gbps'], errors='coerce')
    df['Grid_Size_Num'] = pd.to_numeric(df['Grid_Size'], errors='coerce')
    df['N_Buffer'] = pd.to_numeric(df['N_Buffer'], errors='coerce').fillna(0)

    # Définition des bornes de couleurs globales pour la cohérence des Heatmaps
    v_min = df[df['Mode'] == 'gpu_async']['Throughput_Gbps'].min()
    v_max = df[df['Mode'] == 'gpu_async']['Throughput_Gbps'].max()
    cmap_choice = "YlGnBu" # Cohérence visuelle (Jaune -> Vert -> Bleu Foncé)

    # --- PLOT 1: Peak Performance (RETOUR AUX COULEURS CONTRASTÉES) ---
    plt.figure()
    idx = df.groupby('Mode')['Throughput_Gbps'].idxmax()
    best_df = df.loc[idx].sort_values('Throughput_Gbps').copy()
    labels = []
    for _, row in best_df.iterrows():
        if row['Mode'] == 'cpu': labels.append(f"CPU\n({int(row['Param_Value'])} Thr)")
        elif row['Mode'] == 'gpu': labels.append(f"GPU Sync\n(B:{int(row['Block_Size'])})")
        else: labels.append(f"GPU Async\n(B:{int(row['Block_Size'])}, G:{int(row['Grid_Size_Num'])})")
    best_df['Mode used'] = labels
    # Palette 'deep' pour bien différencier CPU/GPU/Async
    ax = sns.barplot(data=best_df, x='Mode used', y='Throughput_Gbps', hue='Mode used', palette='deep', edgecolor='0.2', legend=False)
    plt.title('Peak Throughput Comparison', fontweight='bold')
    plt.ylabel('Throughput (Gbps)')
    plt.grid(True, axis='y', linestyle='--', alpha=0.4)
    for p in ax.patches:
        ax.annotate(f'{p.get_height():.2f}', (p.get_x() + p.get_width() / 2., p.get_height()),
                    ha='center', va='bottom', fontweight='bold', xytext=(0, 7), textcoords='offset points')
    save_plot('01_Peak_Comparison_Detailed')

    # --- PLOT 2: GPU Async Scalability (RETOUR À LA PALETTE BRIGHT) ---
    plt.figure()
    plt.grid(True, which="both", linestyle='--', alpha=0.5)
    df_async = df[df['Mode'] == 'gpu_async'].sort_values('Grid_Size_Num')
    # Utilisation de 'bright' pour que chaque Block_Size soit bien visible
    sns.lineplot(data=df_async, x='Grid_Size_Num', y='Throughput_Gbps', hue='Block_Size', marker='o', palette='bright', linewidth=2.5)
    plt.xscale('log', base=2)
    plt.gca().xaxis.set_major_formatter(ticker.ScalarFormatter())
    unique_batches = sorted(df_async['Grid_Size_Num'].unique())
    plt.xticks(unique_batches, [int(x) for x in unique_batches], rotation=45)
    plt.title('GPU Async Performance Scaling (95% CI)', fontweight='bold')
    plt.xlabel('Batch Size (Number of packets)')
    plt.ylabel('Throughput (Gbps)')
    plt.legend(title='Block Size', bbox_to_anchor=(1.05, 1), loc='upper left')
    save_plot('02_GPU_Async_Scalability_CI')

    # --- PLOT 3: Optimization Heatmap (Block vs Batch) ---
    plt.figure(figsize=(10, 8))
    pivot_async = df_async.pivot_table(index='Block_Size', columns='Grid_Size_Num', values='Throughput_Gbps', aggfunc='max')
    sns.heatmap(pivot_async, annot=True, fmt=".2f", cmap=cmap_choice, vmin=v_min, vmax=v_max, cbar_kws={'label': 'Gbps'}) 
    plt.title('Optimization Matrix: Block vs Batch Size Efficiency', fontweight='bold')
    plt.xlabel('Batch Size (Number of packets)')
    plt.ylabel('Block Size (Threads per Block)')
    save_plot('03_Optimization_Heatmap')

    # --- PLOT 4: CPU Multi-threading Scalability vs Ideal ---
    plt.figure()
    plt.grid(True, linestyle='--', alpha=0.7)
    df_cpu = df[df['Mode'] == 'cpu'].sort_values('Param_Value')
    
    # Calcul du scaling idéal
    base_tp = df_cpu['Throughput_Gbps'].iloc[0]
    plt.plot(df_cpu['Param_Value'], df_cpu['Throughput_Gbps'], color='tab:red', marker='D', linewidth=3, label='Measured Throughput', markersize=8)
    plt.plot(df_cpu['Param_Value'], df_cpu['Param_Value']*base_tp, color='gray', linestyle='--', alpha=0.6, label='Ideal Linear Scaling')
    
    # --- AJOUT DES ANNOTATIONS DE VALEURS ---
    for x, y in zip(df_cpu['Param_Value'], df_cpu['Throughput_Gbps']):
        plt.annotate(f'{y:.2f}', 
                     (x, y), 
                     textcoords="offset points", 
                     xytext=(0, 10), # Décale le texte de 10 points au-dessus du diamant
                     ha='center', 
                     fontweight='bold', 
                     color='tab:red',
                     fontsize=9)
    
    plt.title('CPU Multi-threading Performance & Efficiency', fontweight='bold')
    plt.xlabel('Number of CPU Threads')
    plt.ylabel('Throughput (Gbps)')
    plt.xticks(df_cpu['Param_Value'].unique())
    
    # On ajuste un peu le haut de l'axe Y pour que les étiquettes ne sortent pas du cadre
    plt.ylim(0, (df_cpu['Param_Value'].max() * base_tp) * 1.1)
    
    plt.legend()
    save_plot('04_CPU_Scalability')

    # --- PLOT 6: N-Buffer Scaling (Annotations intelligentes) ---
    plt.figure()
    plt.grid(True, linestyle='--', alpha=0.6)
    df_n = df[(df['Mode'] == 'gpu_async') & (df['Block_Size'] == 32)].sort_values('N_Buffer')
    if not df_n.empty:
        n_sum = df_n.groupby('N_Buffer')['Throughput_Gbps'].max().reset_index()
        plt.plot(n_sum['N_Buffer'], n_sum['Throughput_Gbps'], marker='o', color='red', linewidth=2.5, markersize=10)
        plt.title(f'Asynchronous Pipeline Optimization', fontweight='bold')
        plt.xlabel('Number of Buffers (N_Buffer)')
        plt.ylabel('Peak Throughput (Gbps)')
        plt.xticks(n_sum['N_Buffer'].unique())
        plt.ylim(n_sum['Throughput_Gbps'].min() - 15, n_sum['Throughput_Gbps'].max() + 25)
        for i, (x, y) in enumerate(zip(n_sum['N_Buffer'], n_sum['Throughput_Gbps'])):
            offset = -2 if i == 0 else 2
            va = 'top' if i == 0 else 'bottom'
            plt.text(x, y + offset, f'{y:.1f}', ha='center', va=va, fontweight='bold', color='darkred')
        save_plot('06_NBuffer_Scaling')

    # --- PLOT 7: Relative Speedup (RETOUR À LA PALETTE MAGMA) ---
    plt.figure()
    plt.grid(True, axis='y', linestyle='--', alpha=0.6)
    max_cpu = df[df['Mode'] == 'cpu']['Throughput_Gbps'].max()
    best_df['Speedup'] = best_df['Throughput_Gbps'] / max_cpu
    # Palette 'magma' pour un aspect dégradé de vitesse
    ax = sns.barplot(data=best_df, x='Mode', y='Speedup', hue='Mode', palette='magma', edgecolor='0.2', legend=False)
    plt.title(f'Relative Speedup Factor (Ref CPU)', fontweight='bold')
    plt.ylabel('Speedup Factor (x)')
    for p in ax.patches:
        ax.annotate(f'{p.get_height():.1f}x', (p.get_x() + p.get_width() / 2., p.get_height()),
                    ha='center', va='bottom', fontweight='bold', xytext=(0, 5), textcoords='offset points')
    save_plot('07_Relative_Speedup')

    # --- PLOT 8: Block Size Impact (RETOUR À LA COULEUR) ---
    plt.figure()
    plt.grid(True, axis='y', linestyle='--', alpha=0.6)
    
    # On groupe pour avoir le max par Block Size
    df_block = df[df['Mode'] == 'gpu_async'].groupby('Block_Size')['Throughput_Gbps'].max().reset_index()
    
    # Utilisation de 'Set1' pour avoir des couleurs très différentes (Rouge, Bleu, Vert, Violet...)
    ax = sns.barplot(
        data=df_block, 
        x='Block_Size', 
        y='Throughput_Gbps', 
        hue='Block_Size', 
        palette='Set1', 
        edgecolor='0.2',
        legend=False
    )
    
    plt.title('Impact of Block Size on GPU Throughput', fontweight='bold')
    plt.xlabel('Threads per Block (Block Size)')
    plt.ylabel('Maximum Throughput (Gbps)')
    
    # Ajout des valeurs au-dessus des barres pour une lecture directe
    for p in ax.patches:
        ax.annotate(f'{p.get_height():.1f}', (p.get_x() + p.get_width() / 2., p.get_height()),
                    ha='center', va='bottom', fontweight='bold', xytext=(0, 5), textcoords='offset points')
    
    save_plot('08_BlockSize_Impact')

    # --- PLOT 10: Heatmap Block vs Buffer ---
    plt.figure(figsize=(10, 8))
    pivot_buff = df[df['Mode'] == 'gpu_async'].pivot_table(index='Block_Size', columns='N_Buffer', values='Throughput_Gbps', aggfunc='max')
    sns.heatmap(pivot_buff, annot=True, fmt=".2f", cmap=cmap_choice, vmin=v_min, vmax=v_max, cbar_kws={'label': 'Gbps'})
    plt.title('Optimization Matrix: Block Size vs. Buffer Count', fontweight='bold')
    plt.xlabel('Number of Buffers (N_Buffer)')
    plt.ylabel('Block Size')
    save_plot('10_Heatmap_Block_vs_Buffer')
    
    # --- PLOT 11: ---
    plt.figure()
    g = sns.FacetGrid(df[df['Mode'] == 'gpu_async'], col="N_Buffer", hue="Block_Size", 
                      col_wrap=3, height=4, palette='bright')
    g.map(sns.lineplot, "Grid_Size_Num", "Throughput_Gbps", marker="o")
    
    g.set_titles("N_Buffer = {col_name}")
    g.set_axis_labels("Batch Size", "Gbps")
    for ax in g.axes.flatten():
        ax.set_xscale('log', base=2)
        ax.grid(True, linestyle='--', alpha=0.5)
    
    g.add_legend(title="Block Size")
    plt.subplots_adjust(top=0.9)
    g.fig.suptitle('Full Scalability Matrix across all Buffer Configurations', fontweight='bold')
    
    # On sauvegarde directement via l'objet FacetGrid
    g.savefig("11_FacetGrid_Full_Analysis.png", dpi=300)
    g.savefig("11_FacetGrid_Full_Analysis.pdf")
    print("✅ Files created: 11_FacetGrid_Full_Analysis.png and .pdf")


    # --- PLOT 12: Global Optimization Matrix (Version Manuelle Compatible) ---
    df_gpu = df[df['Mode'] == 'gpu_async'].copy()
    g = sns.FacetGrid(df_gpu, col="N_Buffer", col_wrap=2, height=5, aspect=1.2)

    def draw_heatmap_manual(data, **kwargs):
        if not data.empty:
            p = data.pivot_table(index='Block_Size', columns='Grid_Size_Num', values='Throughput_Gbps', aggfunc='max')
            sns.heatmap(p, annot=True, fmt=".0f", cmap=cmap_choice, vmin=v_min, vmax=v_max, cbar=False, ax=plt.gca())

    # Utilisation d'une boucle manuelle pour éviter AttributeError: 'FacetGrid' has no attribute 'map_df'
    for (n_val, ax_sub) in g.axes_dict.items():
        plt.sca(ax_sub)
        draw_heatmap_manual(df_gpu[df_gpu['N_Buffer'] == n_val])

    g.set_axis_labels("Batch Size (Packets)", "Block Size (Threads)")
    g.set_titles(col_template="N_Buffers = {col_name}")
    plt.subplots_adjust(top=0.88, hspace=0.35)
    g.fig.suptitle('Global Optimization Matrix: Throughput Analysis', fontweight='bold', fontsize=16)
    g.savefig("12_Global_Optimization_Matrix.png", dpi=300)
    g.savefig("12_Global_Optimization_Matrix.pdf")
    print("✅ Files created: 12_Global_Optimization_Matrix.png and .pdf")

if __name__ == "__main__":
    generate_all_plots("benchmark_results.csv")