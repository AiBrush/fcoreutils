ASM = nasm
ASMFLAGS = -f bin
TARGET = fchgrp
SRC = unified/fchgrp_unified.asm

.PHONY: all clean dev release test

all: $(TARGET)

$(TARGET): $(SRC)
	$(ASM) $(ASMFLAGS) $< -o $@
	chmod +x $@

dev: $(TARGET)

release: $(TARGET)
	cp $(TARGET) $(TARGET)_release

clean:
	rm -f $(TARGET) $(TARGET)_release

test: $(TARGET)
	bash tests/run_tests.sh
