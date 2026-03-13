# chroot — Makefile (uses shared infrastructure)
TARGET     = fchroot
LIB_SRCS   = io.asm args.asm str.asm
UNIFIED_SRC = fchroot_unified.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU chroot ---"
	@hyperfine --warmup 3 'chroot --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do chroot --help > /dev/null 2>&1; done)'
	@echo "--- asm fchroot ---"
	@hyperfine --warmup 3 './fchroot --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ./fchroot --help > /dev/null 2>&1; done)'
