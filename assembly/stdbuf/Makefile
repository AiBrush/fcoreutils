# stdbuf — Makefile (uses shared infrastructure)
TARGET      = fstdbuf
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/fstdbuf.asm
UNIFIED_SRC = fstdbuf_unified.asm

include ../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU stdbuf ---"
	@hyperfine --warmup 3 'stdbuf --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do stdbuf --help > /dev/null 2>&1; done)'
	@echo "--- asm fstdbuf ---"
	@hyperfine --warmup 3 './fstdbuf --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ./fstdbuf --help > /dev/null 2>&1; done)'
