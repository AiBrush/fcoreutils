# printenv — Makefile (uses shared infrastructure)
TARGET      = fprintenv
LIB_SRCS    = io.asm args.asm str.asm
UNIFIED_SRC = fprintenv_unified.asm
TEST_DEP    = release
TEST_BIN    = ./fprintenv_release

include ../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU printenv ---"
	@hyperfine --warmup 3 'printenv HOME' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do printenv HOME > /dev/null 2>&1; done)'
	@echo "--- asm fprintenv ---"
	@hyperfine --warmup 3 './fprintenv_release HOME' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fprintenv_release HOME > /dev/null 2>&1; done)'
