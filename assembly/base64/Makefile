# Makefile for fbase64 — base64 encode/decode tool
TARGET      = fbase64
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/fbase64.asm
UNIFIED_SRC = unified/fbase64_unified.asm

include ../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU base64 ==="
	@dd if=/dev/urandom bs=1M count=10 of=/tmp/bench_b64.bin 2>/dev/null
	@echo "--- GNU base64 encode ---"
	@hyperfine --warmup 3 'base64 /tmp/bench_b64.bin > /dev/null' 2>/dev/null || \
		bash -c 'time base64 /tmp/bench_b64.bin > /dev/null'
	@echo "--- asm fbase64 encode ---"
	@hyperfine --warmup 3 './fbase64 /tmp/bench_b64.bin > /dev/null' 2>/dev/null || \
		bash -c 'time ./fbase64 /tmp/bench_b64.bin > /dev/null'
	@base64 /tmp/bench_b64.bin > /tmp/bench_b64.enc
	@echo "--- GNU base64 decode ---"
	@hyperfine --warmup 3 'base64 -d /tmp/bench_b64.enc > /dev/null' 2>/dev/null || \
		bash -c 'time base64 -d /tmp/bench_b64.enc > /dev/null'
	@echo "--- asm fbase64 decode ---"
	@hyperfine --warmup 3 './fbase64 -d /tmp/bench_b64.enc > /dev/null' 2>/dev/null || \
		bash -c 'time ./fbase64 -d /tmp/bench_b64.enc > /dev/null'
	@rm -f /tmp/bench_b64.bin /tmp/bench_b64.enc
