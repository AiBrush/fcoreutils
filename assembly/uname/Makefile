# uname — Makefile (uses shared infrastructure)
TARGET      = funame
LIB_SRCS    = io.asm args.asm str.asm
UNIFIED_SRC = funame_unified.asm
TEST_DEP    = release
TEST_BIN    = ./funame_release

include ../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU uname ---"
	@hyperfine --warmup 3 'uname' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do uname > /dev/null 2>&1; done)'
	@echo "--- asm funame ---"
	@hyperfine --warmup 3 './funame_release' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./funame_release > /dev/null 2>&1; done)'
