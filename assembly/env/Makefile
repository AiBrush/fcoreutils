# Makefile for fenv — uses shared build infrastructure
TARGET      = fenv
LIB_SRCS    = io.asm args.asm str.asm
UNIFIED_SRC = $(TARGET)_unified.asm
TEST_DEP    = release
TEST_BIN    = ./$(TARGET)_release

include ../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU env ---"
	@hyperfine --warmup 3 'env' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do env > /dev/null 2>&1; done)'
	@echo "--- asm fenv ---"
	@hyperfine --warmup 3 './fenv_release' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fenv_release > /dev/null 2>&1; done)'
