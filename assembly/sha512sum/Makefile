# Makefile for fsha512sum — SHA-512 hash tool (uses shared infrastructure)
TARGET      = fsha512sum
LIB_SRCS    = io.asm str.asm args.asm
UNIFIED_SRC = unified/fsha512sum_unified.asm
TEST_DEP    = release
TEST_BIN    = ./fsha512sum_release

include ../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU sha512sum ==="
	@dd if=/dev/urandom bs=1M count=10 of=/tmp/bench_sha512.bin 2>/dev/null
	@echo "--- GNU sha512sum ---"
	@hyperfine --warmup 3 'sha512sum /tmp/bench_sha512.bin' 2>/dev/null || \
		bash -c 'time sha512sum /tmp/bench_sha512.bin > /dev/null'
	@echo "--- asm fsha512sum ---"
	@hyperfine --warmup 3 './fsha512sum_release < /tmp/bench_sha512.bin' 2>/dev/null || \
		bash -c 'time ./fsha512sum_release < /tmp/bench_sha512.bin > /dev/null'
	@rm -f /tmp/bench_sha512.bin
