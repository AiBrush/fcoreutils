# unlink — Makefile (uses shared infrastructure)
TARGET      = funlink
LIB_SRCS    = io.asm args.asm str.asm
UNIFIED_SRC = funlink_unified.asm
TEST_DEP    = release
TEST_BIN    = ./funlink_release

include ../../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU unlink ---"
	@hyperfine --warmup 3 'unlink /tmp/__bench_dummy 2>/dev/null' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do unlink /tmp/__bench_dummy 2>/dev/null; done)'
	@echo "--- asm funlink ---"
	@hyperfine --warmup 3 './funlink_release /tmp/__bench_dummy 2>/dev/null' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./funlink_release /tmp/__bench_dummy 2>/dev/null; done)'
