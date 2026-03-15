# nice — Makefile (uses shared infrastructure)
TARGET      = fnice
LIB_SRCS    = io.asm args.asm str.asm
UNIFIED_SRC = fnice_unified.asm

include ../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU nice ---"
	@hyperfine --warmup 3 'nice' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do nice > /dev/null 2>&1; done)'
	@echo "--- asm fnice ---"
	@hyperfine --warmup 3 './fnice' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ./fnice > /dev/null 2>&1; done)'
