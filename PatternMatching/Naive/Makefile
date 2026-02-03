.PHONY: clean

clean:
	@echo "Removing file that are not c extension or cuda extension"
	find . -maxdepth 1 -type f -not -name "*.c" -not -name "*.cu" -not -name "Makefile" -not -name "*.txt" -delete
	@echo "Done"