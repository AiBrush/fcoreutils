# Makefile for fsha256sum — SHA-256 hash tool
TARGET      = fsha256sum
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/fsha256sum.asm
UNIFIED_SRC = unified/fsha256sum_unified.asm

include ../../Makefile.inc

# Override dev to build from unified since tools/fsha256sum.asm is a stub
dev: $(UNIFIED_SRC)
	$(NASM) -f bin $(UNIFIED_SRC) -o $(TARGET)
	chmod +x $(TARGET)

bench: dev
	@echo "=== Benchmark vs GNU sha256sum ==="
	@dd if=/dev/urandom bs=1M count=10 of=/tmp/bench_sha256.bin 2>/dev/null
	@echo "--- GNU sha256sum ---"
	@hyperfine --warmup 3 'sha256sum /tmp/bench_sha256.bin' 2>/dev/null || \
		bash -c 'time sha256sum /tmp/bench_sha256.bin > /dev/null'
	@echo "--- asm fsha256sum ---"
	@hyperfine --warmup 3 './fsha256sum < /tmp/bench_sha256.bin' 2>/dev/null || \
		bash -c 'time ./fsha256sum < /tmp/bench_sha256.bin > /dev/null'
	@rm -f /tmp/bench_sha256.bin
