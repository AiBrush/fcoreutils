# Makefile for fls — directory listing tool
TARGET      = fls
LIB_SRCS    = io.asm str.asm
TOOL_SRCS   = tools/fls.asm
UNIFIED_SRC = unified/fls_unified.asm

include ../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ls ==="
	@echo "--- GNU ls ---"
	@hyperfine --warmup 3 'ls /usr/bin' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ls /usr/bin > /dev/null 2>&1; done)'
	@echo "--- asm fls ---"
	@hyperfine --warmup 3 './fls /usr/bin' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ./fls /usr/bin > /dev/null 2>&1; done)'
