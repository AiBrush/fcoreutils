NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections -z noexecstack
BUILD     = build
TARGET    = fls

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

clean:
	rm -rf $(BUILD) $(TARGET) $(TARGET)_release

test: dev
	bash tests/run_tests.sh ./$(TARGET)

bench: dev
	@echo "=== Benchmark vs GNU ls ==="
	@echo "--- GNU ls ---"
	@hyperfine --warmup 3 'ls /usr/bin' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ls /usr/bin > /dev/null 2>&1; done)'
	@echo "--- asm fls ---"
	@hyperfine --warmup 3 './fls /usr/bin' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 100); do ./fls /usr/bin > /dev/null 2>&1; done)'

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) 2>/dev/null
	@echo "--- GNU ls ---"
	@ls -la $$(which ls)
