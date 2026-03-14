# Makefile for fruncon — run command with specified SELinux context
TARGET      = fruncon
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/fruncon.asm
UNIFIED_SRC = fruncon_unified.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU runcon ---"
	@hyperfine --warmup 3 'runcon --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do runcon --help > /dev/null 2>&1; done)'
	@echo "--- asm fruncon ---"
	@hyperfine --warmup 3 './fruncon --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ./fruncon --help > /dev/null 2>&1; done)'
