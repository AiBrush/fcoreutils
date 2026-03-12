NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections -z noexecstack
BUILD     = build
TARGET    = fgroups

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
	@echo "--- GNU groups ---"
	@hyperfine --warmup 3 'groups' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do groups > /dev/null 2>&1; done)'
	@echo "--- asm fgroups ---"
	@hyperfine --warmup 3 './fgroups_release' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fgroups_release > /dev/null 2>&1; done)'

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET)_release 2>/dev/null
	@echo "--- GNU groups ---"
	@ls -la $$(which groups)
