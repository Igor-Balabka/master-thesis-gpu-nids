#ifndef GPU_ENGINE_H
#define GPU_ENGINE_H

#include "config.h"
#include "ac.h"
#include "payload.h"

#ifdef __cplusplus
extern "C" {
#endif

void gpu_init_dfa(const AC_Automata *m);
void gpu_free_dfa(void);

// Vérifie si un Stream spécifique a terminé son travail (non-bloquant)
int gpu_is_stream_ready(int stream_idx);

// Récupère les matchs calculés par un Stream qui vient de se terminer
unsigned long long gpu_collect_stream_matches(int stream_idx);

// Soumission 100% ASYNCHRONE (Retour immédiat sans bloquer le CPU)
void gpu_process_batch_async_submit(const char *h_packet_data, const uint32_t *h_lengths, uint32_t num_pkts, int stream_idx);

// Attente globale à la toute fin du programme
void gpu_synchronize_all(void);

void print_gpu_specs(void);
double run_classic_packet_benchmark(const AC_Automata *m, const MbufPool *pool, int loops, long *out_matches);

#ifdef __cplusplus
}
#endif

#endif // GPU_ENGINE_H