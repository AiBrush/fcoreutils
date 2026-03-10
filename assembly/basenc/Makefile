NASM      = nasm
TARGET    = fbasenc

.PHONY: all dev release clean test bench sizes

all: dev

# Dev build — unified file, nasm -f bin, no linker
dev: unified/fbasenc_unified.asm
	$(NASM) -f bin unified/fbasenc_unified.asm -o $(TARGET)
	chmod +x $(TARGET)

# Release build — same as dev for unified builds
release: dev

clean:
	rm -f $(TARGET)

test: dev
	TOOL=./$(TARGET) bash tests/test_fbasenc.sh

security-test: dev
	python3 tests/security_tests.py

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

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) 2>/dev/null
	@echo "--- GNU basenc ---"
	@ls -la /usr/bin/basenc
