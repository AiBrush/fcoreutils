# Makefile for frmdir — remove empty directories
TARGET      = frmdir
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/frmdir.asm
UNIFIED_SRC = frmdir_unified.asm
TEST_DEP    = release
TEST_BIN    = ./frmdir_release

include ../../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU rmdir ---"
	@hyperfine --warmup 3 'rmdir --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do rmdir --help > /dev/null 2>&1; done)'
	@echo "--- asm frmdir ---"
	@hyperfine --warmup 3 './frmdir_release --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./frmdir_release --help > /dev/null 2>&1; done)'
