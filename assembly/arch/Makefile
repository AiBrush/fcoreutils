AS        = as
LD        = ld
ASFLAGS   = --64 -I ./
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = farch

LIB_SRCS  = lib/io.s lib/args.s lib/str.s
LIB_OBJS  = $(LIB_SRCS:lib/%.s=$(BUILD)/%.o)

.PHONY: all dev release clean test bench sizes

all: dev

$(BUILD):
	mkdir -p $(BUILD)

# Compile lib objects
$(BUILD)/%.o: lib/%.s | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

# Dev build — modular, fast iteration
dev: tools/$(TARGET).s $(LIB_OBJS) | $(BUILD)
	$(AS) $(ASFLAGS) tools/$(TARGET).s -o $(BUILD)/$(TARGET).o
	$(LD) $(LDFLAGS) $(BUILD)/$(TARGET).o $(LIB_OBJS) -o $(TARGET)

# Release build — unified file, minimal binary via custom linker script
release: $(TARGET)_unified.s | $(BUILD)
	$(AS) --64 $(TARGET)_unified.s -o $(BUILD)/$(TARGET)_unified.o
	$(LD) -T release.ld $(BUILD)/$(TARGET)_unified.o -o $(TARGET)_release
	strip --strip-all $(TARGET)_release
	chmod +x $(TARGET)_release

clean:
	rm -rf $(BUILD) $(TARGET) $(TARGET)_release

test: dev
	bash tests/run_tests.sh ./$(TARGET)

bench: dev
	@echo "=== Benchmark vs GNU ==="
	@echo "--- GNU arch ---"
	@hyperfine --warmup 3 'arch' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do arch > /dev/null 2>&1; done)'
	@echo "--- asm farch ---"
	@hyperfine --warmup 3 './farch' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./farch > /dev/null 2>&1; done)'

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) $(TARGET)_release 2>/dev/null || true
	@echo "--- GNU arch ---"
	@ls -la $$(which arch)
	@echo "--- Sections ---"
	@size $(TARGET) 2>/dev/null || true
