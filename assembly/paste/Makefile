NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = fpaste

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
	@echo "=== Benchmark vs GNU paste ==="
	@echo "--- Generating test data ---"
	@python3 -c "import random; lines = [''.join(random.choices('abcdefghijklmnopqrstuvwxyz', k=50)) + '\n' for _ in range(1000000)]; open('/tmp/fpaste_a.txt','w').writelines(lines); open('/tmp/fpaste_b.txt','w').writelines(lines)"
	@echo "--- Two files (default tab delimiter) ---"
	@hyperfine --warmup 3 'paste /tmp/fpaste_a.txt /tmp/fpaste_b.txt > /dev/null' './fpaste /tmp/fpaste_a.txt /tmp/fpaste_b.txt > /dev/null'
	@echo "--- Serial mode ---"
	@hyperfine --warmup 3 'paste -s /tmp/fpaste_a.txt > /dev/null' './fpaste -s /tmp/fpaste_a.txt > /dev/null'
	@rm -f /tmp/fpaste_a.txt /tmp/fpaste_b.txt

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) $(TARGET)_release 2>/dev/null
	@echo "--- GNU paste ---"
	@ls -la $$(which paste)
	@echo "--- Sections ---"
	@size $(TARGET) 2>/dev/null
