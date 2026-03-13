NASM      = nasm
BUILD     = build
TARGET    = fsplit

.PHONY: all release clean test bench sizes

all: release

$(BUILD):
	mkdir -p $(BUILD)

# Release build — unified file, nasm -f bin, no linker
release: unified/$(TARGET)_unified.asm | $(BUILD)
	$(NASM) -f bin unified/$(TARGET)_unified.asm -o $(TARGET)
	chmod +x $(TARGET)

clean:
	rm -rf $(BUILD) $(TARGET) $(TARGET)_release

test: release
	python3 tests/security_tests.py

bench: release
	@echo "=== Benchmark vs GNU ==="
	@seq 100000 > /tmp/bench_split.txt
	@echo "--- GNU split ---"
	@hyperfine --warmup 3 'cd /tmp && rm -f bench_xa* && split /tmp/bench_split.txt bench_x' 2>/dev/null || \
		bash -c 'time (cd /tmp && rm -f bench_xa* && split /tmp/bench_split.txt bench_x)'
	@echo "--- asm fsplit ---"
	@hyperfine --warmup 3 'cd /tmp && rm -f bench_xa* && $(CURDIR)/fsplit /tmp/bench_split.txt bench_x' 2>/dev/null || \
		bash -c 'time (cd /tmp && rm -f bench_xa* && $(CURDIR)/fsplit /tmp/bench_split.txt bench_x)'
	@rm -f /tmp/bench_split.txt /tmp/bench_xa*

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) 2>/dev/null
	@echo "--- GNU split ---"
	@ls -la $$(which split)
