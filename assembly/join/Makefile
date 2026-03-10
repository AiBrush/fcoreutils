NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = fjoin

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
	nasm -f bin -w-zeroing -w-ea-absolute unified/$(TARGET)_unified.asm -o $(TARGET)_release
	chmod +x $(TARGET)_release

clean:
	rm -rf $(BUILD) $(TARGET) $(TARGET)_release

test: dev
	bash tests/run_tests.sh ./$(TARGET)

bench: dev
	@echo "=== Benchmark vs GNU join ==="
	@echo "Generating test data..."
	@seq 1 1000000 | awk '{printf "%07d field_%s\n", $$0, $$0}' | sort > /tmp/fjoin_bench1.txt
	@seq 500001 1500000 | awk '{printf "%07d field_%s\n", $$0, $$0}' | sort > /tmp/fjoin_bench2.txt
	@echo "--- GNU join ---"
	@hyperfine --warmup 3 'join /tmp/fjoin_bench1.txt /tmp/fjoin_bench2.txt > /dev/null' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 5); do join /tmp/fjoin_bench1.txt /tmp/fjoin_bench2.txt > /dev/null; done)'
	@echo "--- asm fjoin ---"
	@hyperfine --warmup 3 './fjoin /tmp/fjoin_bench1.txt /tmp/fjoin_bench2.txt > /dev/null' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 5); do ./fjoin /tmp/fjoin_bench1.txt /tmp/fjoin_bench2.txt > /dev/null; done)'
	@rm -f /tmp/fjoin_bench1.txt /tmp/fjoin_bench2.txt

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) $(TARGET)_release 2>/dev/null
	@echo "--- GNU join ---"
	@ls -la $$(which join)
	@echo "--- Sections ---"
	@size $(TARGET) 2>/dev/null
