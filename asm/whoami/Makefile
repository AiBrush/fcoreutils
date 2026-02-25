NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./ -g -F dwarf
LDFLAGS   = --gc-sections -z noexecstack
BUILD     = build
TARGET    = fwhoami

LIB_SRCS  = lib/io.asm lib/args.asm lib/str.asm
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
release: $(TARGET)_unified.asm
	nasm -f bin $(TARGET)_unified.asm -o $(TARGET)_release
	chmod +x $(TARGET)_release

clean:
	rm -rf $(BUILD) $(TARGET) $(TARGET)_release

test: dev
	bash tests/run_tests.sh ./$(TARGET)

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU whoami ---"
	@hyperfine --warmup 3 'whoami' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do whoami > /dev/null 2>&1; done)'
	@echo "--- asm fwhoami ---"
	@hyperfine --warmup 3 './fwhoami' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fwhoami > /dev/null 2>&1; done)'

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) $(TARGET)_release 2>/dev/null
	@echo "--- GNU whoami ---"
	@ls -la $$(which whoami)
	@echo "--- Sections ---"
	@size $(TARGET) 2>/dev/null
