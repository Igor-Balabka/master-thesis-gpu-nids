CC = gcc
CFLAGS = -Wall -O3 -fopenmp
TARGET = aho_corasick
TEST_TARGET = run_tests

# Compile the main benchmark
all:
	$(CC) $(CFLAGS) main.c ac.c utils.c -o $(TARGET)

# Compile and run unit tests
test:
	$(CC) $(CFLAGS) test.c ac.c -o $(TEST_TARGET)
	./$(TEST_TARGET)

# Clean only the executables
clean:
	rm -f $(TARGET) $(TEST_TARGET)