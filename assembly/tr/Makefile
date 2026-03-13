# Makefile for ftr — tr tool
TARGET      = ftr
LIB_SRCS    = io.asm
TOOL_SRCS   = tools/ftr.asm
UNIFIED_SRC = unified/ftr_unified.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@dd if=/dev/urandom bs=1M count=10 of=/tmp/bench_tr.bin 2>/dev/null
	@echo "--- GNU tr ---"
	@hyperfine --warmup 3 'cat /tmp/bench_tr.bin | tr a-z A-Z > /dev/null' 2>/dev/null || \
		bash -c 'time (cat /tmp/bench_tr.bin | tr a-z A-Z > /dev/null)'
	@echo "--- asm ftr ---"
	@hyperfine --warmup 3 'cat /tmp/bench_tr.bin | ./ftr a-z A-Z > /dev/null' 2>/dev/null || \
		bash -c 'time (cat /tmp/bench_tr.bin | ./ftr a-z A-Z > /dev/null)'
	@rm -f /tmp/bench_tr.bin
