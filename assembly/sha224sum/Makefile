NASM = nasm
NASM_FLAGS = -f bin

UNIFIED_SRC = unified/fsha224sum_unified.asm
UNIFIED_BIN = fsha224sum

.PHONY: all clean test test-security

all: $(UNIFIED_BIN)

$(UNIFIED_BIN): $(UNIFIED_SRC)
	$(NASM) $(NASM_FLAGS) $< -o $@
	chmod +x $@

clean:
	rm -f $(UNIFIED_BIN)

test: $(UNIFIED_BIN)
	bash tests/run_tests.sh ./$(UNIFIED_BIN)

test-security: $(UNIFIED_BIN)
	python3 tests/security_tests.py
