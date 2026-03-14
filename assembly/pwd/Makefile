# pwd — Makefile (uses shared infrastructure)
TARGET      = fpwd
LIB_SRCS    = io.asm args.asm str.asm
UNIFIED_SRC = fpwd_unified.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU pwd ---"
	@hyperfine --warmup 3 '/usr/bin/pwd' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do /usr/bin/pwd > /dev/null 2>&1; done)'
	@echo "--- asm fpwd ---"
	@hyperfine --warmup 3 './fpwd' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fpwd > /dev/null 2>&1; done)'
