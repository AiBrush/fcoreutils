# Makefile for fbase32 — base32 encode/decode tool
# NOTE: base32 currently only has a unified build (no modular tools/ source).
# The shared Makefile.inc dev target won't work until a modular source is added.
TARGET      = fbase32
LIB_SRCS    = io.asm str.asm args.asm
TOOL_SRCS   = tools/fbase32.asm
UNIFIED_SRC = unified/fbase32_unified.asm

include ../../Makefile.inc

# Override dev to build from unified since no modular source exists yet
dev: $(UNIFIED_SRC)
	$(NASM) -f bin $(UNIFIED_SRC) -o $(TARGET)
	chmod +x $(TARGET)

bench: dev
	@echo "=== Benchmark vs GNU base32 ==="
	@dd if=/dev/urandom bs=1M count=10 of=/tmp/bench_b32.bin 2>/dev/null
	@echo "--- GNU base32 encode ---"
	@hyperfine --warmup 3 'base32 /tmp/bench_b32.bin > /dev/null' 2>/dev/null || \
		bash -c 'time base32 /tmp/bench_b32.bin > /dev/null'
	@echo "--- asm fbase32 encode ---"
	@hyperfine --warmup 3 './fbase32 /tmp/bench_b32.bin > /dev/null' 2>/dev/null || \
		bash -c 'time ./fbase32 /tmp/bench_b32.bin > /dev/null'
	@base32 /tmp/bench_b32.bin > /tmp/bench_b32.enc
	@echo "--- GNU base32 decode ---"
	@hyperfine --warmup 3 'base32 -d /tmp/bench_b32.enc > /dev/null' 2>/dev/null || \
		bash -c 'time base32 -d /tmp/bench_b32.enc > /dev/null'
	@echo "--- asm fbase32 decode ---"
	@hyperfine --warmup 3 './fbase32 -d /tmp/bench_b32.enc > /dev/null' 2>/dev/null || \
		bash -c 'time ./fbase32 -d /tmp/bench_b32.enc > /dev/null'
	@rm -f /tmp/bench_b32.bin /tmp/bench_b32.enc
