# unexpand — Makefile (uses shared infrastructure)
TARGET      = funexpand
LIB_SRCS    = io.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark: funexpand vs GNU unexpand ==="
	@dd if=/dev/urandom bs=1M count=50 2>/dev/null | tr '\0-\377' ' -~\n' > /tmp/bench_unexpand.txt 2>/dev/null
	@echo "--- GNU unexpand ---"
	@hyperfine --warmup 3 'unexpand -a /tmp/bench_unexpand.txt > /dev/null' 2>/dev/null || \
		bash -c 'time unexpand -a /tmp/bench_unexpand.txt > /dev/null'
	@echo "--- asm funexpand ---"
	@hyperfine --warmup 3 './funexpand -a /tmp/bench_unexpand.txt > /dev/null' 2>/dev/null || \
		bash -c 'time ./funexpand -a /tmp/bench_unexpand.txt > /dev/null'
	@rm -f /tmp/bench_unexpand.txt
