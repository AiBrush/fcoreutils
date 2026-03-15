# chmod — Makefile (uses shared infrastructure)
TARGET      = fchmod
LIB_SRCS    =
UNIFIED_SRC = fchmod_unified.asm

include ../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU chmod ==="
	@echo "--- GNU chmod ---"
	@hyperfine --warmup 3 'chmod --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do chmod --help > /dev/null 2>&1; done)'
	@echo "--- asm fchmod ---"
	@hyperfine --warmup 3 './fchmod_release --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ./fchmod_release --help > /dev/null 2>&1; done)'
