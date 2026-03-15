# mknod — Makefile (uses shared infrastructure)
TARGET      = fmknod
LIB_SRCS    = io.asm args.asm str.asm
UNIFIED_SRC = fmknod_unified.asm
TEST_DEP    = release
TEST_BIN    = ./fmknod_release

include ../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU mknod ---"
	@hyperfine --warmup 3 'mknod --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do mknod --help > /dev/null 2>&1; done)'
	@echo "--- asm fmknod ---"
	@hyperfine --warmup 3 './fmknod_release --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fmknod_release --help > /dev/null 2>&1; done)'
