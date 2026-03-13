# pr — Makefile (uses shared infrastructure)
TARGET      = fpr
LIB_SRCS    = io.asm
UNIFIED_SRC = unified/fpr_unified.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU pr ==="
	@seq 1 100000 > /tmp/fpr_bench.txt
	@echo "--- GNU pr -t ---"
	@hyperfine --warmup 3 'pr -t /tmp/fpr_bench.txt > /dev/null' 2>/dev/null || \
		bash -c 'time pr -t /tmp/fpr_bench.txt > /dev/null'
	@echo "--- asm fpr -t ---"
	@hyperfine --warmup 3 './fpr -t /tmp/fpr_bench.txt > /dev/null' 2>/dev/null || \
		bash -c 'time ./fpr -t /tmp/fpr_bench.txt > /dev/null'
	@rm -f /tmp/fpr_bench.txt
