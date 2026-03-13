NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = fstdbuf

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

test: dev
	bash tests/run_tests.sh ./$(TARGET)

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU stdbuf ---"
	@hyperfine --warmup 3 'stdbuf --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do stdbuf --help > /dev/null 2>&1; done)'
	@echo "--- asm fstdbuf ---"
	@hyperfine --warmup 3 './fstdbuf --help' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ./fstdbuf --help > /dev/null 2>&1; done)'

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) $(TARGET)_release 2>/dev/null
	@echo "--- GNU stdbuf ---"
	@ls -la $$(which stdbuf 2>/dev/null) 2>/dev/null || echo "not found"
