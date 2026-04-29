# --- Compilateurs ---
CC = gcc
NVCC = nvcc

# --- Flags ---
CFLAGS = -O3 -fopenmp -I.
NVFLAGS = -O3 -arch=sm_80 -Xcompiler -fopenmp -I.
CUDA_LDFLAGS = -lpcap -lcudart -Xcompiler -fopenmp -lm

# --- Fichiers sources ---
SRCS_C = main.c payload.c ac.c
SRCS_CU = Kernel/ac_classic.cu Kernel/ac_double_buffering.cu Kernel/cuda_utils.cu

# --- Cibles ---
TARGET = nids_gpu

all: $(TARGET)

$(TARGET): $(SRCS_C) $(SRCS_CU)
	$(NVCC) $(NVFLAGS) $(SRCS_C) $(SRCS_CU) -o $(TARGET) $(CUDA_LDFLAGS)

# --- RÈGLES DE TEST (Pour test manuel rapide) ---

# GPU Classique (Synchrone)
gpu: $(TARGET)
	./$(TARGET) gpu 1 1 Rules/patterns.txt Pcap/MixFile.pcap 256

# GPU Double Buffering (Asynchrone) - On teste avec 256 par défaut
gpu_async: $(TARGET)
	./$(TARGET) gpu_async 1 1 Rules/patterns.txt Pcap/MixFile.pcap 256

# CPU Multi-thread (12 threads par défaut)
cpu: $(TARGET)
	./$(TARGET) cpu 12 1 Rules/patterns.txt Pcap/MixFile.pcap

clean:
	@echo "🧹 Nettoyage des fichiers objets et de l'exécutable..."
	rm -f $(TARGET)
	rm -f $(ALL_OBJS)
	# Supprime aussi les fichiers de résultats de benchmark si tu veux repartir à zéro
	rm -f benchmark_results.csv
	@echo "✨ Dossier propre."

benchmark: $(TARGET)
	sudo ./run_benchmark.sh

# N'oublie pas d'ajouter gpu_async ici !
.PHONY: all clean gpu gpu_async cpu