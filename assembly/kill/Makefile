NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = fkill

LIB_SRCS  = lib/io.asm lib/args.asm lib/str.asm
LIB_OBJS  = $(LIB_SRCS:lib/%.asm=$(BUILD)/%.o)

.PHONY: all dev release clean test security-test bench sizes

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

security-test: release
	python3 tests/security_tests.py

bench: release
	@echo "=== Benchmark vs system kill (startup-dominated) ==="
	@echo "--- System kill ---"
	@hyperfine --warmup 3 'kill -l' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do kill -l > /dev/null 2>&1; done)'
	@echo "--- asm fkill ---"
	@hyperfine --warmup 3 './fkill_release -l' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fkill_release -l > /dev/null 2>&1; done)'

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET)_release 2>/dev/null
	@echo "--- System kill ---"
	@ls -la $$(which kill)
