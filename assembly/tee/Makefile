# Makefile for ftee — tee tool
TARGET      = ftee
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/ftee.asm
UNIFIED_SRC = ftee_unified.asm
TEST_DEP    = release
TEST_BIN    = ./ftee_release

include ../../Makefile.inc

bench: release
	@echo "=== Benchmark vs GNU ==="
	@dd if=/dev/urandom bs=1M count=10 of=/tmp/bench_tee.bin 2>/dev/null
	@echo "--- GNU tee ---"
	@hyperfine --warmup 3 'cat /tmp/bench_tee.bin | tee /dev/null > /dev/null' 2>/dev/null || \
		bash -c 'time (cat /tmp/bench_tee.bin | tee /dev/null > /dev/null)'
	@echo "--- asm ftee ---"
	@hyperfine --warmup 3 'cat /tmp/bench_tee.bin | ./ftee_release /dev/null > /dev/null' 2>/dev/null || \
		bash -c 'time (cat /tmp/bench_tee.bin | ./ftee_release /dev/null > /dev/null)'
	@rm -f /tmp/bench_tee.bin
