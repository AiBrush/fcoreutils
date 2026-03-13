NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I ./
LDFLAGS   = --gc-sections
BUILD     = build
TARGET    = fcsplit

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
	@seq 10000 > /tmp/bench_csplit.txt
	@echo "--- GNU csplit ---"
	@hyperfine --warmup 3 'cd /tmp && rm -f bench_cs* && csplit -f bench_cs /tmp/bench_csplit.txt 5000' 2>/dev/null || \
		bash -c 'time (cd /tmp && rm -f bench_cs* && csplit -f bench_cs /tmp/bench_csplit.txt 5000)'
	@echo "--- asm fcsplit ---"
	@hyperfine --warmup 3 'cd /tmp && rm -f bench_cs* && $(CURDIR)/fcsplit_release -f bench_cs /tmp/bench_csplit.txt 5000' 2>/dev/null || \
		bash -c 'time (cd /tmp && rm -f bench_cs* && $(CURDIR)/fcsplit_release -f bench_cs /tmp/bench_csplit.txt 5000)'
	@rm -f /tmp/bench_csplit.txt /tmp/bench_cs*

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET)_release 2>/dev/null
	@echo "--- GNU csplit ---"
	@ls -la $$(which csplit)
