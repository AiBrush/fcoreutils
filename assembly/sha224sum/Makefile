# Makefile for fsha224sum — SHA-224 hash tool
TARGET      = fsha224sum
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/fsha224sum.asm
UNIFIED_SRC = unified/fsha224sum_unified.asm

include ../Makefile.inc

# Override dev to build from unified since tools/fsha224sum.asm is a stub
dev: $(UNIFIED_SRC)
	$(NASM) -f bin $(UNIFIED_SRC) -o $(TARGET)
	chmod +x $(TARGET)

bench: dev
	@echo "=== Benchmark vs GNU sha224sum ==="
	@dd if=/dev/urandom bs=1M count=10 of=/tmp/bench_sha224.bin 2>/dev/null
	@echo "--- GNU sha224sum ---"
	@hyperfine --warmup 3 'sha224sum /tmp/bench_sha224.bin' 2>/dev/null || \
		bash -c 'time sha224sum /tmp/bench_sha224.bin > /dev/null'
	@echo "--- asm fsha224sum ---"
	@hyperfine --warmup 3 './fsha224sum < /tmp/bench_sha224.bin' 2>/dev/null || \
		bash -c 'time ./fsha224sum < /tmp/bench_sha224.bin > /dev/null'
	@rm -f /tmp/bench_sha224.bin
