NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = fexpand

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
	@echo "=== Benchmark: fexpand vs GNU expand ==="
	@echo "--- Generate 100MB test file ---"
	@python3 -c "import random; f=open('/tmp/bench_expand.txt','w'); [f.write('\t'.join(['word'+str(j) for j in range(random.randint(1,10))])+'\n') for i in range(2000000)]; f.close()"
	@echo "--- GNU expand ---"
	@hyperfine --warmup 3 'expand /tmp/bench_expand.txt > /dev/null' 2>/dev/null || \
		bash -c 'time expand /tmp/bench_expand.txt > /dev/null'
	@echo "--- asm fexpand ---"
	@hyperfine --warmup 3 './fexpand /tmp/bench_expand.txt > /dev/null' 2>/dev/null || \
		bash -c 'time ./fexpand /tmp/bench_expand.txt > /dev/null'
	@rm -f /tmp/bench_expand.txt

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) $(TARGET)_release 2>/dev/null
	@echo "--- GNU expand ---"
	@ls -la $$(which expand)
	@echo "--- Sections ---"
	@size $(TARGET) 2>/dev/null
