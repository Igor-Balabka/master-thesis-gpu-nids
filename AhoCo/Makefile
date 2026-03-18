# Compilateurs
CC = gcc
NVCC = nvcc

# Flags
CFLAGS = -O3 -fopenmp
NVFLAGS = -O3 -arch=sm_86 -Xcompiler -fopenmp
CUDA_LDFLAGS = -lcudart -Xcompiler -fopenmp

# Paramètres par défaut
THREADS = 12
LOOPS   = 1
RULES   = ./Rules/patterns.txt
DATA    = ./Data/data.bin

# Fichiers sources
SRCS_C = main.c ac.c utils.c
SRCS_CU = gpu_ac.cu
SRCS_TEST = test_nids.c ac.c utils.c gpu_ac.cu

# Exécutables
TARGET = framework_nids
TEST_TARGET = run_tests

# --- RÈGLES DE COMPILATION ---

# Compilation directe : On donne tous les .c et .cu à NVCC d'un coup
$(TARGET): $(SRCS_C) $(SRCS_CU)
	@echo "🚀 Compilation directe en cours (sans fichiers .o)..."
	$(NVCC) $(NVFLAGS) $(SRCS_C) $(SRCS_CU) -o $(TARGET) $(CUDA_LDFLAGS)
	@echo "✅ SUCCESS: $(TARGET) prêt."

all: $(TARGET)

# --- RÈGLES D'EXÉCUTION RAPIDE ---

gpu: $(TARGET)
	./$(TARGET) gpu $(THREADS) $(LOOPS) $(RULES) $(DATA)

gpu_async: $(TARGET)
	./$(TARGET) gpu_async $(THREADS) $(LOOPS) $(RULES) $(DATA)

cpu: $(TARGET)
	./$(TARGET) cpu $(THREADS) $(LOOPS) $(RULES) $(DATA)

# --- TESTS ---

# On compile le test en une ligne aussi
test: $(SRCS_TEST)
	@echo "🧪 Compilation des tests..."
	$(NVCC) $(NVFLAGS) $(SRCS_TEST) -o $(TEST_TARGET) $(CUDA_LDFLAGS)
	@echo "-------------------------------------------"
	@echo "Running Unit Tests..."
	./$(TEST_TARGET)
	@echo "-------------------------------------------"
	rm -f $(TEST_TARGET)

# --- CLEAN ---

clean:
	rm -f $(TARGET) $(TEST_TARGET)
	@echo "🧹 Nettoyage terminé."

.PHONY: all clean test gpu cpu gpu_async