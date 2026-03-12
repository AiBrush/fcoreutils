NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = fpr

LIB_SRCS  = lib/io.asm
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
release: unified/$(TARGET)_unified.asm
	nasm -f bin unified/$(TARGET)_unified.asm -o $(TARGET)_release
	chmod +x $(TARGET)_release

clean:
	rm -rf $(BUILD) $(TARGET) $(TARGET)_release

test: dev
	bash tests/run_tests.sh ./$(TARGET)

bench: dev
	@echo "=== Benchmark vs GNU pr ==="
	@seq 1 100000 > /tmp/fpr_bench.txt
	@echo "--- GNU pr -t ---"
	@hyperfine --warmup 3 'pr -t /tmp/fpr_bench.txt > /dev/null' 2>/dev/null || \
		bash -c 'time pr -t /tmp/fpr_bench.txt > /dev/null'
	@echo "--- asm fpr -t ---"
	@hyperfine --warmup 3 './fpr -t /tmp/fpr_bench.txt > /dev/null' 2>/dev/null || \
		bash -c 'time ./fpr -t /tmp/fpr_bench.txt > /dev/null'
	@rm -f /tmp/fpr_bench.txt

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) $(TARGET)_release 2>/dev/null
	@echo "--- GNU pr ---"
	@ls -la $$(which pr)
	@echo "--- Sections ---"
	@size $(TARGET) 2>/dev/null
