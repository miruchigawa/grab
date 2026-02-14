.PHONY: all clean test

all: grab

grab: main.o
	ld -o grab main.o

main.o: main.asm
	nasm -f elf64 -g -F dwarf main.asm -o main.o

clean:
	rm -f grab main.o

test: grab
	./tests/test.sh
