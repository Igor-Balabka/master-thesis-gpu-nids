import os
import matplotlib.pyplot as plt
import pandas as pd
import seaborn as sns

sns.set_theme(style="whitegrid")
plt.rcParams.update({
    'font.size': 12,
    'font.family': 'sans-serif',
    'axes.labelsize': 14,
    'axes.titlesize': 16,
    'xtick.labelsize': 12,
    'ytick.labelsize': 12,
    'figure.titlesize': 18,
    'pdf.fonttype': 42,
    'ps.fonttype': 42
})

OUTPUT_DIR = "output_plots"
os.makedirs(OUTPUT_DIR, exist_ok=True)

path_h2d = 'max_speed_h2d_scaling.csv'
path_bidir = 'pageable_vs_pinned_scaling_results.csv'

def process_and_plot(csv_path, filename_suffix, title_prefix):
    if not os.path.exists(csv_path) and os.path.exists(f'../{csv_path}'):
        csv_path = f'../{csv_path}'

    if not os.path.exists(csv_path):
        print(f"File not found: {csv_path}")
        return

    df = pd.read_csv(csv_path)

    df_stats = df.groupby('NB_Streams').agg({
        'PAges_Througput': ['mean', 'std'],
        'Pinned_Thourgput': ['mean', 'std']
    }).reset_index()

    df_stats.columns = ['NB_Streams', 'pageable_mean', 'pageable_std', 'pinned_mean', 'pinned_std']
    df_stats = df_stats.fillna(0)

    streams = df_stats['NB_Streams'].tolist()
    x = range(len(streams))
    width = 0.35

    plt.figure(figsize=(10, 6))

    bars1 = plt.bar([p - width/2 for p in x], df_stats['pageable_mean'], width, 
                    yerr=df_stats['pageable_std'], capsize=4, color='#1f77b4', alpha=0.85, label='Pageable Memory', zorder=3)
    bars2 = plt.bar([p + width/2 for p in x], df_stats['pinned_mean'], width, 
                    yerr=df_stats['pinned_std'], capsize=4, color='#2ca02c', alpha=0.85, label='Pinned Memory', zorder=3)

    plt.xlabel('Number of CUDA Streams')
    plt.ylabel('Throughput (Gbps)')
    plt.title(f'{title_prefix} Throughput by Number of Streams', pad=15)
    plt.xticks(x, streams)
    plt.grid(True, linestyle='--', alpha=0.5, zorder=0)
    plt.legend(loc='upper right')

    max_val = max(df_stats['pinned_mean'].max() + df_stats['pinned_std'].max(), df_stats['pageable_mean'].max() + df_stats['pageable_std'].max())
    plt.ylim(0, max_val * 1.2)

    plt.tight_layout()
    output_path = os.path.join(OUTPUT_DIR, f'chart_pcie_scaling_{filename_suffix}.pdf')
    plt.savefig(output_path, format='pdf', bbox_inches='tight')
    plt.close()
    print(f"Generated: {output_path}")

process_and_plot(path_h2d, 'h2d', 'Host-to-Device (H2D)')
process_and_plot(path_bidir, 'bidirectional', 'Bidirectional (H2D + D2H)')