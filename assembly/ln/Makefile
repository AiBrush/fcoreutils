# Makefile for fln — create hard and symbolic links
TARGET      = fln
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/fln.asm
UNIFIED_SRC = fln_unified.asm

include ../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU ln ---"
	@hyperfine --warmup 3 'ln /tmp/bench_src /tmp/bench_dst && rm /tmp/bench_dst' 2>/dev/null || \
		bash -c 'touch /tmp/bench_src; time (for i in $$(seq 100); do ln /tmp/bench_src /tmp/bench_dst_$$i; done); rm -f /tmp/bench_src /tmp/bench_dst_*'
	@echo "--- asm fln ---"
	@hyperfine --warmup 3 './fln_release /tmp/bench_src /tmp/bench_dst && rm /tmp/bench_dst' 2>/dev/null || \
		bash -c 'touch /tmp/bench_src; time (for i in $$(seq 100); do ./fln_release /tmp/bench_src /tmp/bench_dst_$$i; done); rm -f /tmp/bench_src /tmp/bench_dst_*'
