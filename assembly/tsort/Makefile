NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections --strip-all
BUILD     = build
TARGET    = ftsort

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
	@echo "=== Benchmark vs GNU tsort ==="
	@echo "--- Generate test data ---"
	@python3 -c "import random; pairs = []; nodes = list(range(100000)); random.shuffle(nodes); [pairs.append(f'{nodes[i]} {nodes[i+1]}') for i in range(len(nodes)-1)]; print('\n'.join(pairs))" > /tmp/tsort_bench_data.txt 2>/dev/null || true
	@echo "--- GNU tsort ---"
	@hyperfine --warmup 3 'tsort /tmp/tsort_bench_data.txt > /dev/null' 2>/dev/null || \
		bash -c 'time tsort /tmp/tsort_bench_data.txt > /dev/null'
	@echo "--- asm ftsort ---"
	@hyperfine --warmup 3 './ftsort /tmp/tsort_bench_data.txt > /dev/null' 2>/dev/null || \
		bash -c 'time ./ftsort /tmp/tsort_bench_data.txt > /dev/null'

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) $(TARGET)_release 2>/dev/null
	@echo "--- GNU tsort ---"
	@ls -la $$(which tsort)
	@echo "--- Sections ---"
	@size $(TARGET) 2>/dev/null
