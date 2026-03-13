# true — Makefile (uses shared infrastructure)
TARGET     = ftrue
LIB_SRCS   = io.asm args.asm str.asm
UNIFIED_SRC = ftrue_unified.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU true ---"
	@hyperfine --warmup 3 'true' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do true > /dev/null 2>&1; done)'
	@echo "--- asm ftrue ---"
	@hyperfine --warmup 3 './ftrue' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ./ftrue > /dev/null 2>&1; done)'
