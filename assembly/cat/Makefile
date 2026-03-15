# Makefile for fcat — uses shared build infrastructure
TARGET      = fcat
LIB_SRCS    = io.asm
UNIFIED_SRC = unified/$(TARGET)_unified.asm

include ../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU cat ==="
	@dd if=/dev/urandom of=/tmp/fcat_bench_data bs=1M count=100 2>/dev/null
	@echo "--- No flags (zero-copy) ---"
	@hyperfine --warmup 3 'cat /tmp/fcat_bench_data > /dev/null' './fcat /tmp/fcat_bench_data > /dev/null'
	@echo "--- With -n flag ---"
	@hyperfine --warmup 3 'cat -n /tmp/fcat_bench_data > /dev/null' './fcat -n /tmp/fcat_bench_data > /dev/null'
	@rm -f /tmp/fcat_bench_data
