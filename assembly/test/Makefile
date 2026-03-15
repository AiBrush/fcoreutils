# Makefile for ftest — test tool
TARGET      = ftest
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/ftest.asm
UNIFIED_SRC = ftest_unified.asm
TEST_DEP    = release
TEST_BIN    = ./ftest_release

include ../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU test ---"
	@hyperfine --warmup 3 'test -f /etc/passwd' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do test -f /etc/passwd; done)'
	@echo "--- asm ftest ---"
	@hyperfine --warmup 3 './ftest_release -f /etc/passwd' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./ftest_release -f /etc/passwd; done)'
