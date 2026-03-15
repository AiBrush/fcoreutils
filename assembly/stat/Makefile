# stat — Makefile (uses shared infrastructure)
TARGET      = fstat
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/fstat.asm
UNIFIED_SRC = fstat_unified.asm

include ../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU stat ==="
	@echo "--- GNU stat ---"
	@hyperfine --warmup 3 'stat /etc/hosts' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do stat /etc/hosts > /dev/null 2>&1; done)'
	@echo "--- asm fstat ---"
	@hyperfine --warmup 3 './fstat_release /etc/hosts' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fstat_release /etc/hosts > /dev/null 2>&1; done)'
