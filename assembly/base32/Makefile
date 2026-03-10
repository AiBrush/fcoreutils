NASM      = nasm
TARGET    = fbase32

.PHONY: all dev release clean test bench sizes

all: dev

# Dev build — unified file, nasm -f bin, no linker
dev: unified/fbase32_unified.asm
	$(NASM) -f bin unified/fbase32_unified.asm -o $(TARGET)
	chmod +x $(TARGET)

# Release build — same as dev for unified builds
release: dev

clean:
	rm -f $(TARGET)

test: dev
	bash tests/test_fbase32.sh ./$(TARGET)

security-test: dev
	python3 tests/security_tests.py

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

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) 2>/dev/null
	@echo "--- GNU base32 ---"
	@ls -la /usr/bin/base32
