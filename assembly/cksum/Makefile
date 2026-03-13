# cksum — Makefile (uses shared infrastructure)
TARGET      = fcksum
LIB_SRCS    = io.asm args.asm str.asm
UNIFIED_SRC = fcksum_unified.asm
TEST_DEP    = release
TEST_BIN    = ./fcksum_release

include ../../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU cksum ---"
	@hyperfine --warmup 3 'cksum /dev/null' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do cksum /dev/null > /dev/null 2>&1; done)'
	@echo "--- asm fcksum ---"
	@hyperfine --warmup 3 './fcksum_release /dev/null' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fcksum_release /dev/null > /dev/null 2>&1; done)'
