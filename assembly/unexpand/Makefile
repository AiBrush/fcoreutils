NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./ -g -F dwarf
LDFLAGS   = --gc-sections -n
BUILD     = build
TARGET    = funexpand

LIB_SRCS  = lib/io.asm
LIB_OBJS  = $(LIB_SRCS:lib/%.asm=$(BUILD)/%.o)

.PHONY: all dev release clean test bench

all: dev

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%.o: lib/%.asm | $(BUILD)
	$(NASM) $(NASMFLAGS) $< -o $@

dev: tools/$(TARGET).asm $(LIB_OBJS) | $(BUILD)
	$(NASM) $(NASMFLAGS) tools/$(TARGET).asm -o $(BUILD)/$(TARGET).o
	$(LD) $(LDFLAGS) $(BUILD)/$(TARGET).o $(LIB_OBJS) -o $(TARGET)

release: unified/$(TARGET)_unified.asm
	nasm -f bin unified/$(TARGET)_unified.asm -o $(TARGET)_release
	chmod +x $(TARGET)_release

clean:
	rm -rf $(BUILD) $(TARGET) $(TARGET)_release

test: dev
	bash tests/run_tests.sh ./$(TARGET)

bench: dev
	@echo "=== Benchmark: funexpand vs GNU unexpand ==="
	@dd if=/dev/urandom bs=1M count=50 2>/dev/null | tr '\0-\377' ' -~\n' > /tmp/bench_unexpand.txt 2>/dev/null
	@echo "--- GNU unexpand ---"
	@hyperfine --warmup 3 'unexpand -a /tmp/bench_unexpand.txt > /dev/null' 2>/dev/null || \
		bash -c 'time unexpand -a /tmp/bench_unexpand.txt > /dev/null'
	@echo "--- asm funexpand ---"
	@hyperfine --warmup 3 './funexpand -a /tmp/bench_unexpand.txt > /dev/null' 2>/dev/null || \
		bash -c 'time ./funexpand -a /tmp/bench_unexpand.txt > /dev/null'
	@rm -f /tmp/bench_unexpand.txt
