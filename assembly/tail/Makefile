# Makefile for ftail — uses shared build infrastructure
TARGET    = ftail
LIB_SRCS  = io.asm
UNIFIED_SRC = unified/$(TARGET)_unified.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU tail ==="
	@echo "--- seq 100000 | tail -n 10 ---"
	@hyperfine --warmup 3 'seq 100000 | /usr/bin/tail -n 10 > /dev/null' 'seq 100000 | ./ftail -n 10 > /dev/null' 2>&1 || true
