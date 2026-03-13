NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = fln

LIB_SRCS  = lib/io.asm lib/args.asm lib/str.asm
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
release: $(TARGET)_unified.asm
	nasm -f bin $(TARGET)_unified.asm -o $(TARGET)_release
	chmod +x $(TARGET)_release

clean:
	rm -rf $(BUILD) $(TARGET) $(TARGET)_release

test: release
	bash tests/run_tests.sh ./$(TARGET)_release

bench: release
	@echo "=== Benchmark vs GNU (startup-dominated) ==="
	@echo "--- GNU ln ---"
	@hyperfine --warmup 3 'ln /tmp/bench_src /tmp/bench_dst && rm /tmp/bench_dst' 2>/dev/null || \
		bash -c 'touch /tmp/bench_src; time (for i in $$(seq 100); do ln /tmp/bench_src /tmp/bench_dst_$$i; done); rm -f /tmp/bench_src /tmp/bench_dst_*'
	@echo "--- asm fln ---"
	@hyperfine --warmup 3 './fln_release /tmp/bench_src /tmp/bench_dst && rm /tmp/bench_dst' 2>/dev/null || \
		bash -c 'touch /tmp/bench_src; time (for i in $$(seq 100); do ./fln_release /tmp/bench_src /tmp/bench_dst_$$i; done); rm -f /tmp/bench_src /tmp/bench_dst_*'

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET)_release 2>/dev/null
	@echo "--- GNU ln ---"
	@ls -la $$(which ln)
