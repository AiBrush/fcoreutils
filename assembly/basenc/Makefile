# Makefile for fbasenc — uses shared build infrastructure
# fbasenc is unified-only (no modular dev build)
TARGET      = fbasenc
LIB_SRCS    =
UNIFIED_SRC = unified/fbasenc_unified.asm

include ../../Makefile.inc

# Override dev: fbasenc is unified-only, no modular build
dev: $(UNIFIED_SRC)
	$(NASM) -f bin $(UNIFIED_SRC) -o $(TARGET)
	chmod +x $(TARGET)

bench: dev
	@echo "=== Benchmark vs GNU basenc ==="
	@dd if=/dev/urandom bs=1M count=10 of=/tmp/bench_benc.bin 2>/dev/null
	@echo "--- GNU basenc --base64 encode ---"
	@hyperfine --warmup 3 'basenc --base64 /tmp/bench_benc.bin > /dev/null' 2>/dev/null || \
		bash -c 'time basenc --base64 /tmp/bench_benc.bin > /dev/null'
	@echo "--- asm fbasenc --base64 encode ---"
	@hyperfine --warmup 3 './fbasenc --base64 /tmp/bench_benc.bin > /dev/null' 2>/dev/null || \
		bash -c 'time ./fbasenc --base64 /tmp/bench_benc.bin > /dev/null'
	@basenc --base64 /tmp/bench_benc.bin > /tmp/bench_benc.enc
	@echo "--- GNU basenc --base64 decode ---"
	@hyperfine --warmup 3 'basenc --base64 -d /tmp/bench_benc.enc > /dev/null' 2>/dev/null || \
		bash -c 'time basenc --base64 -d /tmp/bench_benc.enc > /dev/null'
	@echo "--- asm fbasenc --base64 decode ---"
	@hyperfine --warmup 3 './fbasenc --base64 -d /tmp/bench_benc.enc > /dev/null' 2>/dev/null || \
		bash -c 'time ./fbasenc --base64 -d /tmp/bench_benc.enc > /dev/null'
	@rm -f /tmp/bench_benc.bin /tmp/bench_benc.enc
