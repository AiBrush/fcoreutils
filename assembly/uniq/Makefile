NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = funiq

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
release: $(TARGET)_unified.asm
	nasm -f bin $(TARGET)_unified.asm -o $(TARGET)_release
	chmod +x $(TARGET)_release

clean:
	rm -rf $(BUILD) $(TARGET) $(TARGET)_release

test: dev
	bash tests/run_tests.sh ./$(TARGET)

bench: dev
	@echo "=== Benchmark vs GNU uniq ==="
	@echo "Generating test data..."
	@python3 -c "import random; lines = ['line_' + str(i % 1000) for i in range(10000000)]; lines.sort(); print('\n'.join(lines))" > /tmp/funiq_bench_data.txt 2>/dev/null || \
		seq 1 10000000 | sort > /tmp/funiq_bench_data.txt
	@echo "--- GNU uniq ---"
	@hyperfine --warmup 3 'uniq /tmp/funiq_bench_data.txt > /dev/null' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 5); do uniq /tmp/funiq_bench_data.txt > /dev/null; done)'
	@echo "--- asm funiq ---"
	@hyperfine --warmup 3 './funiq /tmp/funiq_bench_data.txt > /dev/null' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 5); do ./funiq /tmp/funiq_bench_data.txt > /dev/null; done)'
	@rm -f /tmp/funiq_bench_data.txt

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) $(TARGET)_release 2>/dev/null
	@echo "--- GNU uniq ---"
	@ls -la $$(which uniq)
	@echo "--- Sections ---"
	@size $(TARGET) 2>/dev/null
