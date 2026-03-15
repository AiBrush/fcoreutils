# Makefile for fmkfifo — FIFO creation tool
TARGET      = fmkfifo
LIB_SRCS    = io.asm args.asm str.asm
TOOL_SRCS   = tools/fmkfifo.asm
UNIFIED_SRC = fmkfifo_unified.asm

include ../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU mkfifo ==="
	@echo "--- GNU mkfifo ---"
	@hyperfine --warmup 3 'mkfifo --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do mkfifo --help > /dev/null 2>&1; done)'
	@echo "--- asm fmkfifo ---"
	@hyperfine --warmup 3 './fmkfifo --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fmkfifo --help > /dev/null 2>&1; done)'
