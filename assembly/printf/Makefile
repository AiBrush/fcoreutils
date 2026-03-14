# printf — Makefile (uses shared infrastructure)
TARGET      = fprintf
LIB_SRCS    = io.asm args.asm str.asm
UNIFIED_SRC = fprintf_unified.asm
TEST_DEP    = release
TEST_BIN    = ./fprintf_release

include ../../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU printf ---"
	@hyperfine --warmup 3 'printf "hello\n"' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do printf "hello\n" > /dev/null 2>&1; done)'
	@echo "--- asm fprintf ---"
	@hyperfine --warmup 3 './fprintf_release "hello\n"' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fprintf_release "hello\n" > /dev/null 2>&1; done)'
