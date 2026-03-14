# Makefile for fseq — print a sequence of numbers
TARGET      = fseq
LIB_SRCS    = io.asm str.asm
TOOL_SRCS   = tools/fseq.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU seq ==="
	@echo "--- seq 1 10000000 > /dev/null ---"
	@hyperfine --warmup 3 '/usr/bin/seq 1 10000000 > /dev/null' './fseq 1 10000000 > /dev/null' 2>&1 || true
	@echo ""
	@echo "--- seq 1 1000000 (piped) ---"
	@hyperfine --warmup 3 '/usr/bin/seq 1 1000000 | wc -l > /dev/null' './fseq 1 1000000 | wc -l > /dev/null' 2>&1 || true
