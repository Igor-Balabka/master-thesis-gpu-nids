import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import os
import matplotlib.ticker as ticker

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
    
    df['Grid_Size_Num'] = pd.to_numeric(df['Batch_Size'], errors='coerce') # Batch_Size au lieu de Grid_Size
    df['N_Buffer'] = pd.to_numeric(df['Slots'], errors='coerce').fillna(0) # Slots au lieu de N_Buffer
    df['Param_Value'] = pd.to_numeric(df['Slots'], errors='coerce')        # Pour le CPU, Param_Value = Slots
    
    df_async_test = df[df['Mode'] == 'gpu_async']
    if not df_async_test.empty:
        v_min = df_async_test['Throughput_Gbps'].min()
        v_max = df_async_test['Throughput_Gbps'].max()
    else:
        v_min, v_max = 0, 100 # Valeurs par défaut

    cmap_choice = "YlGnBu"

    # --- PLOT 1 ---
    plt.figure()
    idx = df.groupby('Mode')['Throughput_Gbps'].idxmax()
    best_df = df.loc[idx].sort_values('Throughput_Gbps').copy()
    labels = []
    for _, row in best_df.iterrows():
        if row['Mode'] == 'cpu': labels.append(f"CPU\n({int(row['Param_Value'])} Thr)")
        elif row['Mode'] == 'gpu': labels.append(f"GPU Sync\n(B:{int(row['Block_Size'])})")
        else: labels.append(f"GPU Async\n(B:{int(row['Block_Size'])}, G:{int(row['Grid_Size_Num'])})")
    best_df['Mode used'] = labels
    ax = sns.barplot(data=best_df, x='Mode used', y='Throughput_Gbps', hue='Mode used', palette='deep', edgecolor='0.2', legend=False)
    plt.title('Peak Throughput Comparison', fontweight='bold')
    plt.ylabel('Throughput (Gbps)')
    plt.grid(True, axis='y', linestyle='--', alpha=0.4)
    for p in ax.patches:
        ax.annotate(f'{p.get_height():.2f}', (p.get_x() + p.get_width() / 2., p.get_height()),
                    ha='center', va='bottom', fontweight='bold', xytext=(0, 7), textcoords='offset points')
    save_plot('01_Peak_Comparison_Detailed')

    # --- PLOT 2 ---
    plt.figure()
    plt.grid(True, which="both", linestyle='--', alpha=0.5) # alpha ajouté pour plus de clarté
    df_async = df[df['Mode'] == 'gpu_async'].sort_values('Grid_Size_Num')
    
    # Ajout de errorbar=None pour supprimer l'intervalle de confiance
    sns.lineplot(data=df_async, x='Grid_Size_Num', y='Throughput_Gbps', 
                 hue='Block_Size', marker='o', palette='bright', 
                 linewidth=2.5, errorbar=None) 
    
    plt.xscale('log', base=2)
    plt.gca().xaxis.set_major_formatter(ticker.ScalarFormatter())
    unique_batches = sorted(df_async['Grid_Size_Num'].unique())
    plt.xticks(unique_batches, [int(x) for x in unique_batches], rotation=45)
    
    plt.title('GPU Async Performance Scaling', fontweight='bold') # Titre mis à jour
    plt.xlabel('Batch Size (Number of packets)')
    plt.ylabel('Throughput (Gbps)')
    plt.legend(title='Block Size', bbox_to_anchor=(1.05, 1), loc='upper left')
    save_plot('02_GPU_Async_Scalability_No_CI')

    # --- PLOT 3 ---
    plt.figure(figsize=(10, 8))
    pivot_async = df_async.pivot_table(index='Block_Size', columns='Grid_Size_Num', values='Throughput_Gbps', aggfunc='max')
    sns.heatmap(pivot_async, annot=True, fmt=".2f", cmap=cmap_choice, vmin=v_min, vmax=v_max, cbar_kws={'label': 'Gbps'}) 
    plt.title('Optimization Matrix: Block vs Batch Size Efficiency', fontweight='bold')
    plt.xlabel('Batch Size (Number of packets)')
    plt.ylabel('Block Size (Threads per Block)')
    save_plot('03_Optimization_Heatmap')

    # --- PLOT 4 ---
    plt.figure()
    plt.grid(True, linestyle='--', alpha=0.7)
    df_cpu = df[df['Mode'] == 'cpu'].sort_values('Param_Value')
    
    base_tp = df_cpu['Throughput_Gbps'].iloc[0]
    plt.plot(df_cpu['Param_Value'], df_cpu['Throughput_Gbps'], color='tab:red', marker='D', linewidth=3, label='Measured Throughput', markersize=8)
    plt.plot(df_cpu['Param_Value'], df_cpu['Param_Value']*base_tp, color='gray', linestyle='--', alpha=0.6, label='Ideal Linear Scaling')
    
    for x, y in zip(df_cpu['Param_Value'], df_cpu['Throughput_Gbps']):
        plt.annotate(f'{y:.2f}', 
                     (x, y), 
                     textcoords="offset points", 
                     xytext=(0, 10), 
                     ha='center', 
                     fontweight='bold', 
                     color='tab:red',
                     fontsize=9)
    
    plt.title('CPU Multi-threading Performance & Efficiency', fontweight='bold')
    plt.xlabel('Number of CPU Threads')
    plt.ylabel('Throughput (Gbps)')
    plt.xticks(df_cpu['Param_Value'].unique())
    
    plt.ylim(0, (df_cpu['Param_Value'].max() * base_tp) * 1.1)
    
    plt.legend()
    save_plot('04_CPU_Scalability')

    # --- PLOT 6 ---
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

    # --- PLOT 7 ---
    plt.figure()
    plt.grid(True, axis='y', linestyle='--', alpha=0.6)
    max_cpu = df[df['Mode'] == 'cpu']['Throughput_Gbps'].max()
    best_df['Speedup'] = best_df['Throughput_Gbps'] / max_cpu
    ax = sns.barplot(data=best_df, x='Mode', y='Speedup', hue='Mode', palette='magma', edgecolor='0.2', legend=False)
    plt.title(f'Relative Speedup Factor (Ref CPU)', fontweight='bold')
    plt.ylabel('Speedup Factor (x)')
    for p in ax.patches:
        ax.annotate(f'{p.get_height():.1f}x', (p.get_x() + p.get_width() / 2., p.get_height()),
                    ha='center', va='bottom', fontweight='bold', xytext=(0, 5), textcoords='offset points')
    save_plot('07_Relative_Speedup')

    # --- PLOT 8 ---
    plt.figure()
    plt.grid(True, axis='y', linestyle='--', alpha=0.6)
    
    df_block = df[df['Mode'] == 'gpu_async'].groupby('Block_Size')['Throughput_Gbps'].max().reset_index()
    
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
    
    for p in ax.patches:
        ax.annotate(f'{p.get_height():.1f}', (p.get_x() + p.get_width() / 2., p.get_height()),
                    ha='center', va='bottom', fontweight='bold', xytext=(0, 5), textcoords='offset points')
    
    save_plot('08_BlockSize_Impact')

    # --- PLOT 10 ---
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
    
    g.savefig("11_FacetGrid_Full_Analysis.png", dpi=300)
    g.savefig("11_FacetGrid_Full_Analysis.pdf")
    print("✅ Files created: 11_FacetGrid_Full_Analysis.png and .pdf")


    # --- PLOT 12 ---
    df_gpu = df[df['Mode'] == 'gpu_async'].copy()
    g = sns.FacetGrid(df_gpu, col="N_Buffer", col_wrap=2, height=5, aspect=1.2)

    def draw_heatmap_manual(data, **kwargs):
        if not data.empty:
            p = data.pivot_table(index='Block_Size', columns='Grid_Size_Num', values='Throughput_Gbps', aggfunc='max')
            sns.heatmap(p, annot=True, fmt=".0f", cmap=cmap_choice, vmin=v_min, vmax=v_max, cbar=False, ax=plt.gca())

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
    
    
   # --- PLOT 13: Throughput & Cache Misses vs Block Size ---
    plt.figure()
    target_batch = 262144
    df_plot = df[
        (df['Mode'] == 'gpu_async') & 
        (df['N_Buffer'] == 3) & 
        (df['Grid_Size_Num'] == target_batch)
    ].sort_values('Block_Size')
    
    if not df_plot.empty:
        labels = df_plot['Block_Size'].astype(int).astype(str).tolist()
        x = range(len(labels))
        
        fig, ax1 = plt.subplots()
        plt.grid(True, linestyle='--', alpha=0.3)

        # Axe 1 : Throughput (Barres)
        color1 = 'tab:blue'
        ax1.set_xlabel('Block Size (Threads per Block)')
        ax1.set_ylabel('Throughput (Gbps)', color=color1, fontweight='bold')
        bars = ax1.bar(x, df_plot['Throughput_Gbps'], color=color1, alpha=0.4, label='Throughput (Gbps)')
        ax1.tick_params(axis='y', labelcolor=color1)
        
        # Axe 2 : Cache Misses (Lignes)
        ax2 = ax1.twinx() 
        color2 = 'tab:red'
        ax2.set_ylabel('Cache Miss Rate (%)', color=color2, fontweight='bold')
        ax2.plot(x, df_plot['L1_Miss_Pct'], marker='s', color='darkorange', label='L1 Miss Rate')
        ax2.plot(x, df_plot['L2_Miss_Pct'], marker='o', color='tab:red', label='L2 Miss Rate')
        ax2.tick_params(axis='y', labelcolor=color2)
        ax2.set_ylim(-5, 115)

        # Labels de données pour le Throughput
        for bar in bars:
            height = bar.get_height()
            ax1.annotate(f'{height:.1f}', xy=(bar.get_x() + bar.get_width() / 2, height),
                        xytext=(0, 3), textcoords="offset points", ha='center', va='bottom', fontweight='bold')

        plt.xticks(x, labels)
        plt.title(f'Performance vs. Memory Efficiency (Block Size)\nBatch: {target_batch}, N_Buffer: 3', fontweight='bold')
        
        # Fusion des légendes
        lines, labels_l = ax1.get_legend_handles_labels()
        lines2, labels2 = ax2.get_legend_handles_labels()
        ax2.legend(lines + lines2, labels_l + labels2, loc='upper left', fontsize='small')

        save_plot('13_Throughput_Cache_BlockSize')
        
        
        
    # --- PLOT 14: Throughput & Cache Efficiency vs Batch Size (Harmonized Colors) ---
    plt.figure()
    target_block = 32
    df_plot = df[
        (df['Mode'] == 'gpu_async') & 
        (df['N_Buffer'] == 3) & 
        (df['Block_Size'] == target_block)
    ].sort_values('Grid_Size_Num')
    
    if not df_plot.empty:
        labels = df_plot['Grid_Size_Num'].astype(int).astype(str).tolist()
        x = range(len(labels))
        
        fig, ax1 = plt.subplots()
        plt.grid(True, linestyle='--', alpha=0.3)

        # Axe 1 : Throughput (Barres Bleues comme le Plot 13)
        color_tp = 'tab:blue'
        ax1.set_xlabel('Batch Size (Packets)')
        ax1.set_ylabel('Throughput (Gbps)', color=color_tp, fontweight='bold')
        bars = ax1.bar(x, df_plot['Throughput_Gbps'], color=color_tp, alpha=0.4, label='Throughput (Gbps)')
        ax1.tick_params(axis='y', labelcolor=color_tp)
        
        # Axe 2 : Cache Misses (Orange et Rouge comme le Plot 13)
        ax2 = ax1.twinx()
        color_miss = 'tab:red'
        ax2.set_ylabel('Cache Miss Rate (%)', color=color_miss, fontweight='bold')
        
        # L1 en Orange, L2 en Rouge
        ax2.plot(x, df_plot['L1_Miss_Pct'], marker='s', color='darkorange', linewidth=2, label='L1 Miss Rate')
        ax2.plot(x, df_plot['L2_Miss_Pct'], marker='o', color='tab:red', linewidth=2, label='L2 Miss Rate')
        
        ax2.tick_params(axis='y', labelcolor=color_miss)
        ax2.set_ylim(-5, 115)

        for bar in bars:
            height = bar.get_height()
            ax1.annotate(f'{height:.1f}', xy=(bar.get_x() + bar.get_width() / 2, height),
                        xytext=(0, 3), textcoords="offset points", ha='center', va='bottom', 
                        fontweight='bold', fontsize=9)

        plt.xticks(x, labels, rotation=45)
        plt.title(f'Performance vs. Memory Efficiency (Batch Size)\nBlock: {target_block}, N_Buffer: 3', fontweight='bold')
        
        lines, labels_l = ax1.get_legend_handles_labels()
        lines2, labels2 = ax2.get_legend_handles_labels()
        ax2.legend(lines + lines2, labels_l + labels2, loc='upper left', fontsize='small', frameon=True, shadow=True)

        save_plot('14_Throughput_Cache_BatchSize_Harmonized')
    else:
        print(f"⚠️ Skip Plot 14: No data for gpu_async with Block_Size={target_block} and N_Buffer=3")

if __name__ == "__main__":
    generate_all_plots("benchmark_results.csv")