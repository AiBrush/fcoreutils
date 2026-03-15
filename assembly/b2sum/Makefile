# Makefile for fb2sum — BLAKE2b hash tool
TARGET      = fb2sum
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/fb2sum.asm
UNIFIED_SRC = unified/fb2sum_unified.asm

include ../Makefile.inc

# Override dev to build from unified since tools/fb2sum.asm is a placeholder
dev: $(UNIFIED_SRC)
	$(NASM) -f bin $(UNIFIED_SRC) -o $(TARGET)
	chmod +x $(TARGET)

bench: dev
	@echo "=== Benchmark vs GNU b2sum ==="
	@dd if=/dev/urandom bs=1M count=10 of=/tmp/bench_b2sum.bin 2>/dev/null
	@echo "--- GNU b2sum ---"
	@hyperfine --warmup 3 'b2sum /tmp/bench_b2sum.bin' 2>/dev/null || \
		bash -c 'time b2sum /tmp/bench_b2sum.bin > /dev/null'
	@echo "--- asm fb2sum ---"
	@hyperfine --warmup 3 './fb2sum < /tmp/bench_b2sum.bin' 2>/dev/null || \
		bash -c 'time ./fb2sum < /tmp/bench_b2sum.bin > /dev/null'
	@rm -f /tmp/bench_b2sum.bin
