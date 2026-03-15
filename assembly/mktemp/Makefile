# mktemp — Makefile (uses shared infrastructure)
TARGET      = fmktemp
LIB_SRCS    = io.asm args.asm str.asm
UNIFIED_SRC = fmktemp_unified.asm
TEST_DEP    = release
TEST_BIN    = ./fmktemp_release

include ../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU mktemp ---"
	@hyperfine --warmup 3 'mktemp --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do mktemp --help > /dev/null 2>&1; done)'
	@echo "--- asm fmktemp ---"
	@hyperfine --warmup 3 './fmktemp_release --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fmktemp_release --help > /dev/null 2>&1; done)'
