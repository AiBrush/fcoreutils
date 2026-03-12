NASM      = nasm
TARGET    = fshred

.PHONY: all dev release clean test bench

all: dev

# Dev build = release build (unified single-file binary)
dev: unified/$(TARGET)_unified.asm
	nasm -f bin unified/$(TARGET)_unified.asm -o $(TARGET)
	chmod +x $(TARGET)

# Release build
release: unified/$(TARGET)_unified.asm
	nasm -f bin unified/$(TARGET)_unified.asm -o $(TARGET)_release
	chmod +x $(TARGET)_release

clean:
	rm -f $(TARGET) $(TARGET)_release

test: dev
	bash tests/run_tests.sh ./$(TARGET)

bench: dev
	@echo "=== Benchmark vs GNU shred ==="
	@dd if=/dev/urandom of=/tmp/fshred_bench_data bs=1M count=100 2>/dev/null
	@echo "--- Default (3 passes) ---"
	@hyperfine --warmup 1 'shred -n 3 /tmp/fshred_bench_data' './fshred -n 3 /tmp/fshred_bench_data'
	@echo "--- Single pass ---"
	@hyperfine --warmup 1 'shred -n 1 /tmp/fshred_bench_data' './fshred -n 1 /tmp/fshred_bench_data'
	@rm -f /tmp/fshred_bench_data
