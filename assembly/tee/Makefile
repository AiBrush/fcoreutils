NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = ftee

LIB_SRCS  = lib/io.asm lib/args.asm lib/str.asm
LIB_OBJS  = $(LIB_SRCS:lib/%.asm=$(BUILD)/%.o)

.PHONY: all dev release clean test bench sizes

all: dev

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%.o: lib/%.asm | $(BUILD)
	$(NASM) $(NASMFLAGS) $< -o $@

dev: tools/$(TARGET).asm $(LIB_OBJS) | $(BUILD)
	$(NASM) $(NASMFLAGS) tools/$(TARGET).asm -o $(BUILD)/$(TARGET).o
	$(LD) $(LDFLAGS) $(BUILD)/$(TARGET).o $(LIB_OBJS) -o $(TARGET)

release: $(TARGET)_unified.asm
	nasm -f bin $(TARGET)_unified.asm -o $(TARGET)_release
	chmod +x $(TARGET)_release

clean:
	rm -rf $(BUILD) $(TARGET) $(TARGET)_release

test: release
	bash tests/run_tests.sh ./$(TARGET)_release

bench: release
	@echo "=== Benchmark vs GNU ==="
	@dd if=/dev/urandom bs=1M count=10 of=/tmp/bench_tee.bin 2>/dev/null
	@echo "--- GNU tee ---"
	@hyperfine --warmup 3 'cat /tmp/bench_tee.bin | tee /dev/null > /dev/null' 2>/dev/null || \
		bash -c 'time (cat /tmp/bench_tee.bin | tee /dev/null > /dev/null)'
	@echo "--- asm ftee ---"
	@hyperfine --warmup 3 'cat /tmp/bench_tee.bin | ./ftee_release /dev/null > /dev/null' 2>/dev/null || \
		bash -c 'time (cat /tmp/bench_tee.bin | ./ftee_release /dev/null > /dev/null)'
	@rm -f /tmp/bench_tee.bin

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET)_release 2>/dev/null
	@echo "--- GNU tee ---"
	@ls -la $$(which tee)
