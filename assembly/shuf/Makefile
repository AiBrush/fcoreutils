NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = fshuf

LIB_SRCS  = lib/io.asm lib/str.asm
LIB_OBJS  = $(LIB_SRCS:lib/%.asm=$(BUILD)/%.o)

.PHONY: all dev release clean test bench sizes

all: dev

$(BUILD):
	mkdir -p $(BUILD)

# Compile lib objects
$(BUILD)/%.o: lib/%.asm | $(BUILD)
	$(NASM) $(NASMFLAGS) $< -o $@

# Dev build — modular, fast iteration
dev: tools/$(TARGET).asm $(LIB_OBJS) | $(BUILD)
	$(NASM) $(NASMFLAGS) tools/$(TARGET).asm -o $(BUILD)/$(TARGET).o
	$(LD) $(LDFLAGS) $(BUILD)/$(TARGET).o $(LIB_OBJS) -o $(TARGET)

# Release build — unified file, nasm -f bin, no linker
release: unified/$(TARGET)_unified.asm
	nasm -f bin unified/$(TARGET)_unified.asm -o $(TARGET)_release
	chmod +x $(TARGET)_release

clean:
	rm -rf $(BUILD) $(TARGET) $(TARGET)_release

test: dev
	bash tests/run_tests.sh ./$(TARGET)

bench: dev
	@echo "=== Benchmark vs GNU shuf ==="
	@echo "--- Generate test data ---"
	@seq 1 1000000 > /tmp/shuf_bench_data.txt 2>/dev/null || true
	@echo "--- GNU shuf ---"
	@hyperfine --warmup 3 'shuf /tmp/shuf_bench_data.txt > /dev/null' 2>/dev/null || \
		bash -c 'time shuf /tmp/shuf_bench_data.txt > /dev/null'
	@echo "--- asm fshuf ---"
	@hyperfine --warmup 3 './fshuf /tmp/shuf_bench_data.txt > /dev/null' 2>/dev/null || \
		bash -c 'time ./fshuf /tmp/shuf_bench_data.txt > /dev/null'

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) $(TARGET)_release 2>/dev/null
	@echo "--- GNU shuf ---"
	@ls -la $$(which shuf)
	@echo "--- Sections ---"
	@size $(TARGET) 2>/dev/null
