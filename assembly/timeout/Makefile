# Makefile for ftimeout — timeout tool
TARGET      = ftimeout
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/ftimeout.asm
UNIFIED_SRC = ftimeout_unified.asm

include ../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU timeout ---"
	@hyperfine --warmup 3 'timeout 1 true' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do timeout 1 true > /dev/null 2>&1; done)'
	@echo "--- asm ftimeout ---"
	@hyperfine --warmup 3 './ftimeout 1 true' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ./ftimeout 1 true > /dev/null 2>&1; done)'
