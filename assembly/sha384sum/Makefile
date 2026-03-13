# Makefile for fsha384sum — SHA-384 hash tool
TARGET      = fsha384sum
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/fsha384sum.asm
UNIFIED_SRC = unified/fsha384sum_unified.asm

include ../../Makefile.inc

# Override dev to build from unified since tools/fsha384sum.asm is a stub
dev: $(UNIFIED_SRC)
	$(NASM) -f bin $(UNIFIED_SRC) -o $(TARGET)
	chmod +x $(TARGET)

bench: dev
	@echo "=== Benchmark vs GNU sha384sum ==="
	@dd if=/dev/urandom bs=1M count=10 of=/tmp/bench_sha384.bin 2>/dev/null
	@echo "--- GNU sha384sum ---"
	@hyperfine --warmup 3 'sha384sum /tmp/bench_sha384.bin' 2>/dev/null || \
		bash -c 'time sha384sum /tmp/bench_sha384.bin > /dev/null'
	@echo "--- asm fsha384sum ---"
	@hyperfine --warmup 3 './fsha384sum < /tmp/bench_sha384.bin' 2>/dev/null || \
		bash -c 'time ./fsha384sum < /tmp/bench_sha384.bin > /dev/null'
	@rm -f /tmp/bench_sha384.bin
