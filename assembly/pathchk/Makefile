# pathchk — Makefile (uses shared infrastructure)
TARGET      = fpathchk
LIB_SRCS    = io.asm args.asm str.asm
UNIFIED_SRC = fpathchk_unified.asm
TEST_DEP    = release
TEST_BIN    = ./fpathchk_release

include ../../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU pathchk ---"
	@hyperfine --warmup 3 'pathchk /usr/bin/sort' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do pathchk /usr/bin/sort > /dev/null 2>&1; done)'
	@echo "--- asm fpathchk ---"
	@hyperfine --warmup 3 './fpathchk_release /usr/bin/sort' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fpathchk_release /usr/bin/sort > /dev/null 2>&1; done)'
