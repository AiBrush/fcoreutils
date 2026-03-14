# ptx — Makefile (uses shared infrastructure)
TARGET      = fptx
LIB_SRCS    = io.asm args.asm str.asm
UNIFIED_SRC = fptx_unified.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU ptx ---"
	@hyperfine --warmup 3 'ptx --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ptx --help > /dev/null 2>&1; done)'
	@echo "--- asm fptx ---"
	@hyperfine --warmup 3 './fptx --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ./fptx --help > /dev/null 2>&1; done)'
