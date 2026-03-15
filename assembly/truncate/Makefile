# truncate — Makefile (uses shared infrastructure)
# truncate only has a unified build (no tools/ directory)
TARGET     = ftruncate
LIB_SRCS   = io.asm args.asm str.asm
UNIFIED_SRC = ftruncate_unified.asm
TEST_DEP   = release
TEST_BIN   = ./ftruncate_release

include ../Makefile.inc

# Override default: truncate only supports unified/release build
all: release

bench: release
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU truncate ---"
	@hyperfine --warmup 3 'truncate -s 0 /tmp/bench_trunc' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do truncate -s 0 /tmp/bench_trunc > /dev/null 2>&1; done)'
	@echo "--- asm ftruncate ---"
	@hyperfine --warmup 3 './ftruncate_release -s 0 /tmp/bench_trunc' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./ftruncate_release -s 0 /tmp/bench_trunc > /dev/null 2>&1; done)'
