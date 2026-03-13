# pinky — Makefile (uses shared infrastructure)
TARGET      = fpinky
LIB_SRCS    = io.asm args.asm str.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU pinky ---"
	@hyperfine --warmup 3 'pinky --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do pinky --help > /dev/null 2>&1; done)'
	@echo "--- asm fpinky ---"
	@hyperfine --warmup 3 './fpinky --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ./fpinky --help > /dev/null 2>&1; done)'
