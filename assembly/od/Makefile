NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./ -g -F dwarf
LDFLAGS   = --gc-sections -n
BUILD     = build
TARGET    = fod

LIB_SRCS  = lib/io.asm
LIB_OBJS  = $(LIB_SRCS:lib/%.asm=$(BUILD)/%.o)

.PHONY: all dev release clean test bench sizes

all: dev

$(BUILD):
	mkdir -p $(BUILD)

# Compile lib objects
$(BUILD)/%.o: lib/%.asm | $(BUILD)
	$(NASM) $(NASMFLAGS) $< -o $@

# Dev build — modular, fast iteration, includes debug symbols
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
	@echo "=== Benchmark vs GNU od ==="
	@dd if=/dev/urandom of=/tmp/od_bench.bin bs=1M count=100 2>/dev/null
	@echo "--- GNU od -t x1 ---"
	@hyperfine --warmup 3 'od -t x1 /tmp/od_bench.bin > /dev/null' 2>/dev/null || \
		bash -c 'time od -t x1 /tmp/od_bench.bin > /dev/null'
	@echo "--- asm fod -t x1 ---"
	@hyperfine --warmup 3 './fod -t x1 /tmp/od_bench.bin > /dev/null' 2>/dev/null || \
		bash -c 'time ./fod -t x1 /tmp/od_bench.bin > /dev/null'
	@rm -f /tmp/od_bench.bin

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) $(TARGET)_release 2>/dev/null
	@echo "--- GNU od ---"
	@ls -la $$(which od)
	@echo "--- Sections ---"
	@size $(TARGET) 2>/dev/null
