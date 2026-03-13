# stty — Makefile (uses shared infrastructure)
TARGET      = fstty
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/fstty.asm
UNIFIED_SRC = fstty_unified.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU stty ---"
	@hyperfine --warmup 3 'stty --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do stty --help > /dev/null 2>&1; done)'
	@echo "--- asm fstty ---"
	@hyperfine --warmup 3 './fstty --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ./fstty --help > /dev/null 2>&1; done)'
