# Makefile for fecho — uses shared build infrastructure
TARGET      = fecho
LIB_SRCS    = io.asm args.asm str.asm
UNIFIED_SRC = $(TARGET)_unified.asm

include ../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU echo ---"
	@hyperfine --warmup 3 '/usr/bin/echo hello world' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do /usr/bin/echo hello world > /dev/null 2>&1; done)'
	@echo "--- asm fecho ---"
	@hyperfine --warmup 3 './fecho hello world' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fecho hello world > /dev/null 2>&1; done)'
