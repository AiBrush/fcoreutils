# tsort — Makefile (uses shared infrastructure)
TARGET     = ftsort
LIB_SRCS   = io.asm
LDFLAGS    = --gc-sections --strip-all
UNIFIED_SRC = unified/ftsort_unified.asm

include ../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU tsort ==="
	@echo "--- Generate test data ---"
	@python3 -c "import random; pairs = []; nodes = list(range(100000)); random.shuffle(nodes); [pairs.append(f'{nodes[i]} {nodes[i+1]}') for i in range(len(nodes)-1)]; print('\n'.join(pairs))" > /tmp/tsort_bench_data.txt 2>/dev/null || true
	@echo "--- GNU tsort ---"
	@hyperfine --warmup 3 'tsort /tmp/tsort_bench_data.txt > /dev/null' 2>/dev/null || \
		bash -c 'time tsort /tmp/tsort_bench_data.txt > /dev/null'
	@echo "--- asm ftsort ---"
	@hyperfine --warmup 3 './ftsort /tmp/tsort_bench_data.txt > /dev/null' 2>/dev/null || \
		bash -c 'time ./ftsort /tmp/tsort_bench_data.txt > /dev/null'
