NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = fdd

LIB_SRCS  = lib/io.asm lib/args.asm lib/str.asm
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
release: $(TARGET)_unified.asm
	nasm -f bin $(TARGET)_unified.asm -o $(TARGET)_release
	chmod +x $(TARGET)_release

clean:
	rm -rf $(BUILD) $(TARGET) $(TARGET)_release

test: release
	bash tests/run_tests.sh ./$(TARGET)_release

bench: release
	@echo "=== Benchmark vs GNU ==="
	@dd if=/dev/zero bs=1M count=100 of=/tmp/bench_dd.bin 2>/dev/null
	@echo "--- GNU dd ---"
	@hyperfine --warmup 3 'dd if=/tmp/bench_dd.bin of=/dev/null bs=64k 2>/dev/null' 2>/dev/null || \
		bash -c 'time (dd if=/tmp/bench_dd.bin of=/dev/null bs=64k 2>/dev/null)'
	@echo "--- asm fdd ---"
	@hyperfine --warmup 3 './fdd_release if=/tmp/bench_dd.bin of=/dev/null bs=64k 2>/dev/null' 2>/dev/null || \
		bash -c 'time (./fdd_release if=/tmp/bench_dd.bin of=/dev/null bs=64k 2>/dev/null)'
	@rm -f /tmp/bench_dd.bin

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET)_release 2>/dev/null
	@echo "--- GNU dd ---"
	@ls -la $$(which dd)
