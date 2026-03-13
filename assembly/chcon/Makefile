# Makefile for fchcon — uses shared build infrastructure
TARGET    = fchcon
LIB_SRCS  = io.asm args.asm str.asm
UNIFIED_SRC = $(TARGET)_unified.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU chcon ---"
	@hyperfine --warmup 3 'chcon --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do chcon --help > /dev/null 2>&1; done)'
	@echo "--- asm fchcon ---"
	@hyperfine --warmup 3 './fchcon --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ./fchcon --help > /dev/null 2>&1; done)'
