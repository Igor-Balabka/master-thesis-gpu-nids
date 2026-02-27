# Compilateurs
CC = gcc
NVCC = nvcc

# Flags
CFLAGS = -O3 -fopenmp
NVFLAGS = -O3 -arch=sm_75 -Xcompiler -fopenmp

# Fichiers objets
OBJS = main.o ac.o utils.o gpu_ac.o

# Exécutable final
TARGET = framework_nids

all: $(TARGET)

# Linkage final et nettoyage automatique des .o
$(TARGET): $(OBJS)
	$(NVCC) $(NVFLAGS) -o $(TARGET) $(OBJS)
	@echo "Nettoyage des fichiers objets..."
	rm -f $(OBJS)

# Règle pour compiler les fichiers .c
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Règle pour compiler les fichiers .cu
%.o: %.cu
	$(NVCC) $(NVFLAGS) -c $< -o $@

# Nettoie tout (y compris l'exécutable)
clean:
	rm -f *.o $(TARGET)