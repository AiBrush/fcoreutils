# Makefile for flogname — print user's login name
TARGET      = flogname
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/flogname.asm
UNIFIED_SRC = flogname_unified.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU logname ---"
	@hyperfine --warmup 3 'logname' 2>/dev/null || \
		time (for i in $$(seq 100); do logname > /dev/null 2>&1; done)
	@echo "--- asm flogname ---"
	@hyperfine --warmup 3 './flogname' 2>/dev/null || \
		time (for i in $$(seq 100); do ./flogname > /dev/null 2>&1; done)
