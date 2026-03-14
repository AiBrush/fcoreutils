# split — Makefile (uses shared infrastructure)
TARGET      = fsplit
LIB_SRCS    =
UNIFIED_SRC = unified/fsplit_unified.asm

include ../../Makefile.inc

# Override dev to build from unified since no modular source exists yet
dev: $(UNIFIED_SRC)
	$(NASM) -f bin $(UNIFIED_SRC) -o $(TARGET)
	chmod +x $(TARGET)

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@seq 100000 > /tmp/bench_split.txt
	@echo "--- GNU split ---"
	@hyperfine --warmup 3 'cd /tmp && rm -f bench_xa* && split /tmp/bench_split.txt bench_x' 2>/dev/null || \
		bash -c 'time (cd /tmp && rm -f bench_xa* && split /tmp/bench_split.txt bench_x)'
	@echo "--- asm fsplit ---"
	@hyperfine --warmup 3 'cd /tmp && rm -f bench_xa* && $(CURDIR)/fsplit /tmp/bench_split.txt bench_x' 2>/dev/null || \
		bash -c 'time (cd /tmp && rm -f bench_xa* && $(CURDIR)/fsplit /tmp/bench_split.txt bench_x)'
	@rm -f /tmp/bench_split.txt /tmp/bench_xa*
