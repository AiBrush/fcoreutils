# Makefile for fmkdir — directory creation tool
TARGET      = fmkdir
LIB_SRCS    = io.asm args.asm str.asm
TOOL_SRCS   = tools/fmkdir.asm
UNIFIED_SRC = fmkdir_unified.asm

include ../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU mkdir ==="
	@echo "--- GNU mkdir ---"
	@hyperfine --warmup 3 'mkdir --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do mkdir --help > /dev/null 2>&1; done)'
	@echo "--- asm fmkdir ---"
	@hyperfine --warmup 3 './fmkdir --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fmkdir --help > /dev/null 2>&1; done)'
