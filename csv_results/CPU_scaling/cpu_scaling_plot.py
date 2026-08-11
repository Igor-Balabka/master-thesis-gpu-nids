import os
import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns

# Configuration style graphique académique
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

# 1. Gestion automatique des dossiers de sortie
OUTPUT_DIR = "output_plots"
os.makedirs(OUTPUT_DIR, exist_ok=True)

# Détection du fichier CSV
csv_path = 'cpu_scaling_results.csv'
if not os.path.exists(csv_path) and os.path.exists('../cpu_scaling_results.csv'):
    csv_path = '../cpu_scaling_results.csv'

df = pd.read_csv(csv_path)

# Moyenne (mean) ET Écart-Type (std) des 5 runs par nombre de cœurs
df_stats = df.groupby('cores').agg({
    'throughput_gbps': ['mean', 'std'],
    'l1d_miss_pct': ['mean', 'std'],
    'l2_miss_pct': ['mean', 'std'],
    'l3_miss_pct': ['mean', 'std'],
    'dram_bw_gbps': ['mean', 'std']
}).reset_index()

# Aplatissement des colonnes
df_stats.columns = ['cores', 
                    'throughput_mean', 'throughput_std',
                    'l1d_mean', 'l1d_std',
                    'l2_mean', 'l2_std',
                    'l3_mean', 'l3_std',
                    'dram_bw_mean', 'dram_bw_std']

# Remplace les NaN par 0
df_stats = df_stats.fillna(0)

# ------------------------------------------------------------------------------
# CHART 1: Effective Throughput vs. Core Count (Mean ± Std)
# ------------------------------------------------------------------------------
plt.figure(figsize=(10, 6))

plt.plot(df_stats['cores'], df_stats['throughput_mean'], marker='o', color='#1f77b4', linewidth=2.5, markersize=8, label='Throughput (Gbps)')
plt.fill_between(df_stats['cores'], 
                 df_stats['throughput_mean'] - df_stats['throughput_std'], 
                 df_stats['throughput_mean'] + df_stats['throughput_std'], 
                 color='#1f77b4', alpha=0.2)

# Annotation du pic de performance à 7 cœurs
peak_cores = 7
peak_throughput = df_stats.loc[df_stats['cores'] == peak_cores, 'throughput_mean'].values[0]
plt.annotate(f'Peak: {peak_throughput:.2f} Gbps', 
             xy=(peak_cores, peak_throughput), 
             xytext=(peak_cores - 2.2, peak_throughput + 0.6),
             arrowprops=dict(facecolor='black', shrink=0.05, width=1, headwidth=6),
             fontweight='bold', color='#d62728')

plt.title('CPU Multi-Core Processing Scaling', pad=15)
plt.xlabel('CPU Cores')
plt.ylabel('Throughput (Gbps)')
plt.xticks(range(1, 13))
plt.ylim(0, 14)
plt.legend(loc='upper right')
plt.tight_layout()
plt.savefig(os.path.join(OUTPUT_DIR, 'chart1_throughput_scaling_en.pdf'), format='pdf', bbox_inches='tight')
plt.close()

# ------------------------------------------------------------------------------
# CHART 2: Cache Miss Rates (%) L1D, L2, and L3 (Mean ± Std)
# ------------------------------------------------------------------------------
plt.figure(figsize=(10, 6))

# L3 Miss
plt.plot(df_stats['cores'], df_stats['l3_mean'], marker='s', color='#d62728', linewidth=2, label='L3 Cache Miss Rate (%)')
plt.fill_between(df_stats['cores'], df_stats['l3_mean'] - df_stats['l3_std'], df_stats['l3_mean'] + df_stats['l3_std'], color='#d62728', alpha=0.15)

# L1D Miss
plt.plot(df_stats['cores'], df_stats['l1d_mean'], marker='o', color='#ff7f0e', linewidth=2, label='L1 Cache Miss Rate (%)')
plt.fill_between(df_stats['cores'], df_stats['l1d_mean'] - df_stats['l1d_std'], df_stats['l1d_mean'] + df_stats['l1d_std'], color='#ff7f0e', alpha=0.15)

# L2 Miss
plt.plot(df_stats['cores'], df_stats['l2_mean'], marker='^', color='#2ca02c', linewidth=2, label='L2 Cache Miss Rate (%)')
plt.fill_between(df_stats['cores'], df_stats['l2_mean'] - df_stats['l2_std'], df_stats['l2_mean'] + df_stats['l2_std'], color='#2ca02c', alpha=0.15)

plt.title('Cache Miss Rates Across Core Scaling', pad=15)
plt.xlabel('CPU Cores')
plt.ylabel('Cache Miss Rate (%)')
plt.xticks(range(1, 13))
plt.ylim(0, 22)
plt.legend(loc='upper right')
plt.tight_layout()
plt.savefig(os.path.join(OUTPUT_DIR, 'chart2_cache_misses_en.pdf'), format='pdf', bbox_inches='tight')
plt.close()

# ------------------------------------------------------------------------------
# CHART 3: Effective DRAM Bandwidth vs. Core Count (Mean ± Std)
# ------------------------------------------------------------------------------
plt.figure(figsize=(10, 6))

plt.plot(df_stats['cores'], df_stats['dram_bw_mean'], marker='D', color='#9467bd', linewidth=2.5, markersize=8, label='DRAM Bandwidth (GB/s)')
plt.fill_between(df_stats['cores'], 
                 df_stats['dram_bw_mean'] - df_stats['dram_bw_std'], 
                 df_stats['dram_bw_mean'] + df_stats['dram_bw_std'], 
                 color='#9467bd', alpha=0.2)

plt.title('Memory Bus Utilization', pad=15)
plt.xlabel('CPU Cores')
plt.ylabel('Memory Bandwidth (GB/s)')
plt.xticks(range(1, 13))
plt.ylim(0, 14)
plt.legend(loc='upper right')
plt.tight_layout()
plt.savefig(os.path.join(OUTPUT_DIR, 'chart3_dram_bandwidth_en.pdf'), format='pdf', bbox_inches='tight')
plt.close()

print(f"✅ Clean PDF Vector plots generated in '{OUTPUT_DIR}/':")
print(f"   1. {OUTPUT_DIR}/chart1_throughput_scaling_en.pdf")
print(f"   2. {OUTPUT_DIR}/chart2_cache_misses_en.pdf")
print(f"   3. {OUTPUT_DIR}/chart3_dram_bandwidth_en.pdf")