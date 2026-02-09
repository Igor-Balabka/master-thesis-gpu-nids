CC = gcc
CFLAGS = -Wall -O3
OBJ = main.o ac.o


main: $(OBJ)
	$(CC) $(CFLAGS) -o main $(OBJ)

main.o: main.c ac.h
	$(CC) $(CFLAGS) -c main.c


ac.o: ac.c ac.h
	$(CC) $(CFLAGS) -c ac.c


clean:
	rm -f *.o main