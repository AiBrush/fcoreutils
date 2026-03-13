NASM      = nasm
TARGET    = fsum

.PHONY: all release clean test

all: release

# Release build — unified file, nasm -f bin, no linker
release: $(TARGET)_unified.asm
	nasm -f bin $(TARGET)_unified.asm -o $(TARGET)_release
	chmod +x $(TARGET)_release

clean:
	rm -f $(TARGET)_release

test: release
	bash tests/run_tests.sh ./$(TARGET)_release

bench: release
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU sum ---"
	@hyperfine --warmup 3 'sum /usr/bin/sort' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do sum /usr/bin/sort > /dev/null 2>&1; done)'
	@echo "--- asm fsum ---"
	@hyperfine --warmup 3 './fsum_release /usr/bin/sort' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fsum_release /usr/bin/sort > /dev/null 2>&1; done)'

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET)_release 2>/dev/null
	@echo "--- GNU sum ---"
	@ls -la $$(which sum)
