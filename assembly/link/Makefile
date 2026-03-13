# Makefile for flink — create hard links via link()
TARGET      = flink
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/flink.asm
UNIFIED_SRC = flink_unified.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU link ---"
	@hyperfine --warmup 3 'link /tmp/bench_src /tmp/bench_dst && rm /tmp/bench_dst' 2>/dev/null || \
		bash -c 'touch /tmp/bench_src; time (for i in $$(seq 100); do link /tmp/bench_src /tmp/bench_dst_$$i; done); rm -f /tmp/bench_src /tmp/bench_dst_*'
	@echo "--- asm flink ---"
	@hyperfine --warmup 3 './flink_release /tmp/bench_src /tmp/bench_dst && rm /tmp/bench_dst' 2>/dev/null || \
		bash -c 'touch /tmp/bench_src; time (for i in $$(seq 100); do ./flink_release /tmp/bench_src /tmp/bench_dst_$$i; done); rm -f /tmp/bench_src /tmp/bench_dst_*'
