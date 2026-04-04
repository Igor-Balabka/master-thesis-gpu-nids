TARGET = main

CC = gcc

CFLAGS = -Wall -Wextra

LIBS = -lpcap

SRC = main.c payload.c

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $(TARGET) $(SRC) $(LIBS)

clean:
	rm -f $(TARGET)

run: all
	./$(TARGET)