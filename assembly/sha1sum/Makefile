NASM = nasm
NASM_FLAGS = -f bin

TARGET = fsha1sum
SRC = unified/fsha1sum_unified.asm

.PHONY: all clean test

all: $(TARGET)

$(TARGET): $(SRC)
	$(NASM) $(NASM_FLAGS) $< -o $@
	chmod +x $@

clean:
	rm -f $(TARGET)

test: $(TARGET)
	bash tests/run_tests.sh ./$(TARGET)
