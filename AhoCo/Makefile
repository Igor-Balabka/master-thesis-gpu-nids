# Compilateurs
CC = gcc
NVCC = nvcc

# Flags
CFLAGS = -O3 -fopenmp
NVFLAGS = -O3 -arch=sm_86 -Xcompiler -fopenmp
CUDA_LDFLAGS = -lcudart -Xcompiler -fopenmp

# Paramètres par défaut pour l'exécution
THREADS = 12
LOOPS   = 1
RULES   = ./Rules/patterns.txt
DATA    = ./Data/data.bin

# Dossiers
OBJ_DIR = obj

# Fichiers sources
SRCS_C = main.c ac.c utils.c
SRCS_CU = gpu_ac.cu
SRCS_TEST = test_nids.c

# Fichiers objets
OBJS = $(SRCS_C:%.c=$(OBJ_DIR)/%.o) $(SRCS_CU:%.cu=$(OBJ_DIR)/%.o)
TEST_OBJS = $(OBJ_DIR)/ac.o $(OBJ_DIR)/utils.o $(OBJ_DIR)/gpu_ac.o $(OBJ_DIR)/test_nids.o

# Exécutables
TARGET = framework_nids
TEST_TARGET = run_tests

# --- RÈGLES DE COMPILATION ---

all: $(OBJ_DIR) $(TARGET)

$(TARGET): $(OBJS)
	$(NVCC) $(NVFLAGS) -o $(TARGET) $(OBJS) $(CUDA_LDFLAGS)
	@echo "SUCCESS: $(TARGET) prêt."

# --- RÈGLES D'EXÉCUTION RAPIDE ---

# Lance le code en mode GPU
gpu: $(TARGET)
	./$(TARGET) gpu $(THREADS) $(LOOPS) $(RULES) $(DATA)

# Lance le code en mode CPU
cpu: $(TARGET)
	./$(TARGET) cpu $(THREADS) $(LOOPS) $(RULES) $(DATA)

# --- TESTS ET CLEAN ---

test: $(OBJ_DIR) $(TEST_OBJS)
	$(NVCC) $(NVFLAGS) -o $(TEST_TARGET) $(TEST_OBJS) $(CUDA_LDFLAGS)
	@echo "-------------------------------------------"
	@echo "Running Unit Tests..."
	./$(TEST_TARGET)
	@echo "-------------------------------------------"

$(OBJ_DIR):
	mkdir -p $(OBJ_DIR)

$(OBJ_DIR)/%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJ_DIR)/%.o: %.cu
	$(NVCC) $(NVFLAGS) -c $< -o $@

clean:
	rm -rf $(OBJ_DIR) $(TARGET) $(TEST_TARGET)

.PHONY: all clean test gpu cpu