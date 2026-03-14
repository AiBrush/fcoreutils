# comm — Makefile (uses shared infrastructure)
TARGET      = fcomm
LIB_SRCS    = io.asm
UNIFIED_SRC = unified/fcomm_unified.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU comm ==="
	@echo "Generating test data..."
	@seq 1 1000000 | sort > /tmp/fcomm_bench1.txt
	@seq 500001 1500000 | sort > /tmp/fcomm_bench2.txt
	@echo "--- GNU comm ---"
	@hyperfine --warmup 3 'comm /tmp/fcomm_bench1.txt /tmp/fcomm_bench2.txt > /dev/null' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 5); do comm /tmp/fcomm_bench1.txt /tmp/fcomm_bench2.txt > /dev/null; done)'
	@echo "--- asm fcomm ---"
	@hyperfine --warmup 3 './fcomm /tmp/fcomm_bench1.txt /tmp/fcomm_bench2.txt > /dev/null' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 5); do ./fcomm /tmp/fcomm_bench1.txt /tmp/fcomm_bench2.txt > /dev/null; done)'
	@rm -f /tmp/fcomm_bench1.txt /tmp/fcomm_bench2.txt
