import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import os

# --- Academic Vector Settings ---
plt.rcParams.update({
    'font.size': 12,
    'axes.edgecolor': 'black',
    'axes.linewidth': 1.5,
    'grid.color': '#B0B0B0', # Grille un peu plus sombre pour la projection
    'grid.alpha': 0.6,
    'grid.linestyle': '--',
    'figure.autolayout': True,
    'svg.fonttype': 'none', # Garde le texte éditable dans PowerPoint
    'pdf.fonttype': 42
})

def save_plot(name):
    """Sauvegarde en deux formats vectoriels d'un coup"""
    plt.savefig(f"{name}.pdf", format='pdf')
    plt.savefig(f"{name}.svg", format='svg')
    print(f"✅ Saved: {name}.svg & .pdf")

def generate_all_assets(csv_file):
    if not os.path.exists(csv_file):
        print(f"❌ Error: {csv_file} not found.")
        return

    df = pd.read_csv(csv_file)
    
    # Cleaning & Numeric Conversion
    for col in ['Throughput_Gbps', 'Block_Size', 'Grid_Size', 'Param_Value']:
        df[col] = pd.to_numeric(df[col], errors='coerce')

    # Data Splits
    df_cpu = df[df['Mode'] == 'cpu'].sort_values('Param_Value')
    df_sync = df[df['Mode'] == 'gpu'].sort_values(['Block_Size', 'Grid_Size'])
    df_async = df[df['Mode'] == 'gpu_async'].sort_values(['Block_Size', 'Grid_Size'])

    # 1. GPU ASYNC SCALABILITY (The Star of your Presentation)
    if not df_async.empty:
        plt.figure(figsize=(10, 6))
        sns.lineplot(data=df_async, x='Grid_Size', y='Throughput_Gbps', hue='Block_Size', 
                     palette='bright', marker='o', markersize=8, linewidth=2.5)
        plt.title('GPU Asynchronous Performance vs. Grid Configuration', fontweight='bold')
        plt.xlabel('Grid Size (Number of CUDA Blocks)')
        plt.ylabel('Throughput (Gbps)')
        plt.xscale('log', base=2)
        plt.grid(True, which="both")
        xticks = sorted(df_async['Grid_Size'].unique())
        plt.xticks(xticks, xticks)
        plt.legend(title='Threads per Block', frameon=True, shadow=True)
        save_plot('01_GPU_Async_Scalability')
        plt.close()

    # 2. HEATMAP SYNC
    if not df_sync.empty:
        plt.figure(figsize=(10, 8))
        pivot_sync = df_sync.pivot_table(index='Block_Size', columns='Grid_Size', values='Throughput_Gbps')
        sns.heatmap(pivot_sync, annot=True, fmt=".2f", cmap="YlGnBu", cbar_kws={'label': 'Gbps'})
        plt.title('Heatmap: GPU Synchronous Throughput', fontweight='bold')
        save_plot('02_Heatmap_Sync')
        plt.close()

    # 3. HEATMAP ASYNC
    if not df_async.empty:
        plt.figure(figsize=(10, 8))
        pivot_async = df_async.pivot_table(index='Block_Size', columns='Grid_Size', values='Throughput_Gbps')
        sns.heatmap(pivot_async, annot=True, fmt=".2f", cmap="YlGnBu", cbar_kws={'label': 'Gbps'})
        plt.title('Heatmap: GPU Asynchronous Throughput', fontweight='bold')
        save_plot('03_Heatmap_Async')
        plt.close()

    # 4. STABILITY BOXPLOT
    plt.figure(figsize=(10, 6))
    gpu_only = df[df['Mode'].isin(['gpu', 'gpu_async'])].copy()
    gpu_only['Mode'] = gpu_only['Mode'].replace({'gpu': 'Sync', 'gpu_async': 'Async'})
    sns.boxplot(data=gpu_only, x='Mode', y='Throughput_Gbps', hue='Mode', palette='Set2', legend=False)
    plt.title('Throughput Stability: Sync vs Async', fontweight='bold')
    plt.grid(True, axis='y')
    save_plot('04_Stability_Boxplot')
    plt.close()

    # 5. CPU SCALABILITY
    if not df_cpu.empty:
        plt.figure(figsize=(8, 5))
        plt.plot(df_cpu['Param_Value'], df_cpu['Throughput_Gbps'], color='red', marker='D', linewidth=2)
        plt.title('CPU Multithreading Efficiency', fontweight='bold')
        plt.xlabel('Number of Threads')
        plt.ylabel('Throughput (Gbps)')
        plt.grid(True)
        save_plot('05_CPU_Scalability')
        plt.close()

    # 6. FINAL COMPARISON
    plt.figure(figsize=(10, 6))
    best = df.groupby('Mode')['Throughput_Gbps'].max().sort_values().reset_index()
    best['Mode'] = best['Mode'].replace({'cpu': 'CPU', 'gpu': 'GPU Sync', 'gpu_async': 'GPU Async'})
    ax = sns.barplot(data=best, x='Mode', y='Throughput_Gbps', hue='Mode', palette='viridis', legend=False)
    plt.title('Peak Performance Comparison', fontweight='bold')
    plt.grid(True, axis='y')
    for p in ax.patches:
        ax.annotate(f'{p.get_height():.2f}', (p.get_x() + p.get_width()/2., p.get_height()),
                    ha='center', va='bottom', fontweight='bold', xytext=(0, 5), textcoords='offset points')
    save_plot('06_Final_Comparison')
    plt.close()

if __name__ == "__main__":
    generate_all_assets("benchmark_results.csv")