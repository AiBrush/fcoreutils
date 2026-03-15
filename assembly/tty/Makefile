# tty — Makefile (uses shared infrastructure)
TARGET     = ftty
LIB_SRCS   = io.asm args.asm str.asm
UNIFIED_SRC = ftty_unified.asm

include ../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU tty ---"
	@hyperfine --warmup 3 'tty' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do tty > /dev/null 2>&1; done)'
	@echo "--- asm ftty ---"
	@hyperfine --warmup 3 './ftty' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./ftty > /dev/null 2>&1; done)'
