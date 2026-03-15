# uniq — Makefile (uses shared infrastructure)
TARGET      = funiq
LIB_SRCS    = io.asm

include ../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU uniq ==="
	@echo "Generating test data..."
	@python3 -c "import random; lines = ['line_' + str(i % 1000) for i in range(10000000)]; lines.sort(); print('\n'.join(lines))" > /tmp/funiq_bench_data.txt 2>/dev/null || \
		seq 1 10000000 | sort > /tmp/funiq_bench_data.txt
	@echo "--- GNU uniq ---"
	@hyperfine --warmup 3 'uniq /tmp/funiq_bench_data.txt > /dev/null' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 5); do uniq /tmp/funiq_bench_data.txt > /dev/null; done)'
	@echo "--- asm funiq ---"
	@hyperfine --warmup 3 './funiq /tmp/funiq_bench_data.txt > /dev/null' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 5); do ./funiq /tmp/funiq_bench_data.txt > /dev/null; done)'
	@rm -f /tmp/funiq_bench_data.txt
