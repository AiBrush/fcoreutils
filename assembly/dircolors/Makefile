NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = fdircolors

LIB_SRCS  = lib/io.asm lib/args.asm lib/str.asm
LIB_OBJS  = $(LIB_SRCS:lib/%.asm=$(BUILD)/%.o)

.PHONY: all dev release clean test bench sizes

all: dev

$(BUILD):
	mkdir -p $(BUILD)

# Compile lib objects
$(BUILD)/%.o: lib/%.asm | $(BUILD)
	$(NASM) $(NASMFLAGS) $< -o $@

# Dev build — unified flat binary (same as release for dircolors)
dev: $(TARGET)_unified.asm
	nasm -f bin $(TARGET)_unified.asm -o $(TARGET)
	chmod +x $(TARGET)

# Release build — unified file, nasm -f bin, no linker
release: $(TARGET)_unified.asm
	nasm -f bin $(TARGET)_unified.asm -o $(TARGET)_release
	chmod +x $(TARGET)_release

clean:
	rm -rf $(BUILD) $(TARGET) $(TARGET)_release

test: release
	bash tests/run_tests.sh ./$(TARGET)_release

bench: release
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU dircolors ---"
	@hyperfine --warmup 3 'dircolors' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do dircolors > /dev/null 2>&1; done)'
	@echo "--- asm fdircolors ---"
	@hyperfine --warmup 3 './fdircolors_release' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./fdircolors_release > /dev/null 2>&1; done)'

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET)_release 2>/dev/null
	@echo "--- GNU dircolors ---"
	@ls -la $$(which dircolors)
