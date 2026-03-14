# Makefile for fdirname — uses shared build infrastructure
TARGET      = fdirname
LIB_SRCS    = io.asm args.asm str.asm
UNIFIED_SRC = $(TARGET)_unified.asm
TEST_DEP    = release
TEST_BIN    = ./$(TARGET)_release

include ../../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU dirname ---"
	@hyperfine --warmup 3 'dirname /usr/bin/sort' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do dirname /usr/bin/sort > /dev/null 2>&1; done)'
	@echo "--- asm fdirname ---"
	@hyperfine --warmup 3 './fdirname_release /usr/bin/sort' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fdirname_release /usr/bin/sort > /dev/null 2>&1; done)'
