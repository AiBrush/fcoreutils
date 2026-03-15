# Makefile for fmd5sum — MD5 hash tool
TARGET      = fmd5sum
LIB_SRCS    = io.asm str.asm
TOOL_SRCS   = tools/fmd5sum.asm
UNIFIED_SRC = unified/fmd5sum_unified.asm

include ../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU md5sum ==="
	@dd if=/dev/urandom bs=1M count=10 of=/tmp/bench_md5.bin 2>/dev/null
	@echo "--- GNU md5sum ---"
	@hyperfine --warmup 3 'md5sum /tmp/bench_md5.bin' 2>/dev/null || \
		bash -c 'time md5sum /tmp/bench_md5.bin > /dev/null'
	@echo "--- asm fmd5sum ---"
	@hyperfine --warmup 3 './fmd5sum /tmp/bench_md5.bin' 2>/dev/null || \
		bash -c 'time ./fmd5sum /tmp/bench_md5.bin > /dev/null'
	@rm -f /tmp/bench_md5.bin
