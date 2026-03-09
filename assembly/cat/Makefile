NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./ -g -F dwarf
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = fcat

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
	@echo "=== Benchmark vs GNU cat ==="
	@dd if=/dev/urandom of=/tmp/fcat_bench_data bs=1M count=100 2>/dev/null
	@echo "--- No flags (zero-copy) ---"
	@hyperfine --warmup 3 'cat /tmp/fcat_bench_data > /dev/null' './fcat /tmp/fcat_bench_data > /dev/null'
	@echo "--- With -n flag ---"
	@hyperfine --warmup 3 'cat -n /tmp/fcat_bench_data > /dev/null' './fcat -n /tmp/fcat_bench_data > /dev/null'
	@rm -f /tmp/fcat_bench_data

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) $(TARGET)_release 2>/dev/null
	@echo "--- GNU cat ---"
	@ls -la $$(which cat)
	@echo "--- Sections ---"
	@size $(TARGET) 2>/dev/null
