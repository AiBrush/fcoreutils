NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = finstall

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
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "test file" > /tmp/bench_install_src
	@echo "--- GNU install ---"
	@hyperfine --warmup 3 'install /tmp/bench_install_src /tmp/bench_install_dst' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do install /tmp/bench_install_src /tmp/bench_install_dst; done)'
	@echo "--- asm finstall ---"
	@hyperfine --warmup 3 './finstall_release /tmp/bench_install_src /tmp/bench_install_dst' 2>/dev/null || \
		bash -c 'time (for i in $$(seq 1000); do ./finstall_release /tmp/bench_install_src /tmp/bench_install_dst; done)'
	@rm -f /tmp/bench_install_src /tmp/bench_install_dst

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET)_release 2>/dev/null
	@echo "--- GNU install ---"
	@ls -la $$(which install)
