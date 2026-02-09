CC = gcc
CFLAGS = -Wall -O3 -fopenmp 
SRC = main.c ac.c

benchmark: $(SRC) ac.h
	$(CC) $(CFLAGS) -o benchmark $(SRC)

clean:
	rm -f benchmark