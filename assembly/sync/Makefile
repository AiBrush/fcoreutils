# Makefile for fsync — uses shared build infrastructure
TARGET    = fsync
LIB_SRCS  = io.asm args.asm str.asm
UNIFIED_SRC = $(TARGET)_unified.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU sync ---"
	@hyperfine --warmup 3 'sync' 2>/dev/null || \
		time (for i in $$(seq 100); do sync > /dev/null 2>&1; done)
	@echo "--- asm fsync ---"
	@hyperfine --warmup 3 './fsync' 2>/dev/null || \
		time (for i in $$(seq 100); do ./fsync > /dev/null 2>&1; done)
