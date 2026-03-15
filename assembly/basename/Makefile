# Makefile for fbasename — uses shared build infrastructure
TARGET    = fbasename
LIB_SRCS  = io.asm args.asm str.asm
UNIFIED_SRC = $(TARGET)_unified.asm
TEST_DEP  = release
TEST_BIN  = ./$(TARGET)_release

include ../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU basename ---"
	@hyperfine --warmup 3 'basename /usr/bin/sort' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do basename /usr/bin/sort > /dev/null 2>&1; done)'
	@echo "--- asm fbasename ---"
	@hyperfine --warmup 3 './fbasename_release /usr/bin/sort' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fbasename_release /usr/bin/sort > /dev/null 2>&1; done)'
