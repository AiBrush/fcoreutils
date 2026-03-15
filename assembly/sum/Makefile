# Makefile for fsum — uses shared build infrastructure
TARGET    = fsum
LIB_SRCS  = io.asm args.asm str.asm
UNIFIED_SRC = $(TARGET)_unified.asm
TEST_DEP  = release
TEST_BIN  = ./$(TARGET)_release

include ../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU sum ---"
	@hyperfine --warmup 3 'sum /usr/bin/sort' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do sum /usr/bin/sort > /dev/null 2>&1; done)'
	@echo "--- asm fsum ---"
	@hyperfine --warmup 3 './fsum_release /usr/bin/sort' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fsum_release /usr/bin/sort > /dev/null 2>&1; done)'
