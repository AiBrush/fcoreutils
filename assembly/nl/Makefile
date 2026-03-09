NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./ -g -F dwarf
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = fnl

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
	@echo "=== Benchmark vs GNU nl ==="
	@seq 1 1000000 > /tmp/nl_bench.txt
	@echo "--- GNU nl ---"
	@hyperfine --warmup 3 'nl /tmp/nl_bench.txt > /dev/null' 2>/dev/null || \
		bash -c 'time nl /tmp/nl_bench.txt > /dev/null'
	@echo "--- asm fnl ---"
	@hyperfine --warmup 3 './fnl /tmp/nl_bench.txt > /dev/null' 2>/dev/null || \
		bash -c 'time ./fnl /tmp/nl_bench.txt > /dev/null'
	@rm -f /tmp/nl_bench.txt

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) $(TARGET)_release 2>/dev/null
	@echo "--- GNU nl ---"
	@ls -la $$(which nl)
	@echo "--- Sections ---"
	@size $(TARGET) 2>/dev/null
