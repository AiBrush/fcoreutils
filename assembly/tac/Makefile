# Makefile for ftac — uses shared build infrastructure
TARGET    = ftac
LIB_SRCS  = io.asm
UNIFIED_SRC = unified/$(TARGET)_unified.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU tac ==="
	@echo "--- seq 100000 | tac > /dev/null ---"
	@hyperfine --warmup 3 'seq 100000 | /usr/bin/tac > /dev/null' 'seq 100000 | ./ftac > /dev/null' 2>&1 || true
