CC = gcc
CFLAGS = -Wall -O3 -fopenmp
TARGET = aho_corasick

all: $(TARGET)

$(TARGET): main.o ac.o utils.o
	$(CC) $(CFLAGS) -o $(TARGET) main.o ac.o utils.o

main.o: main.c ac.h utils.h
	$(CC) $(CFLAGS) -c main.c

ac.o: ac.c ac.h
	$(CC) $(CFLAGS) -c ac.c

utils.o: utils.c utils.h
	$(CC) $(CFLAGS) -c utils.c

clean:
	rm -f *.o $(TARGET)