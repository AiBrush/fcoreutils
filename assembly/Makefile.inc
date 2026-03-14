# Makefile.inc — Shared Makefile template for fcoreutils assembly tools
#
# Each tool Makefile sets these variables, then includes this file:
#   TARGET      — binary name (e.g., fseq)
#   LIB_SRCS    — shared lib filenames (e.g., io.asm str.asm)
#   TOOL_SRCS   — tool source files (default: tools/$(TARGET).asm)
#   UNIFIED_SRC — unified asm file for release build
#   TEST_DEP    — test dependency target (default: dev)
#   TEST_BIN    — binary used for testing (default: ./$(TARGET))

NASM          ?= nasm
LD            ?= ld
NASMFLAGS     ?= -f elf64 -I ./ -I ../../lib/
LDFLAGS       ?= --gc-sections
BUILD         ?= build
SHARED_LIB_DIR = ../../lib

TOOL_SRCS     ?= tools/$(TARGET).asm
UNIFIED_SRC   ?= $(TARGET)_unified.asm
TEST_DEP      ?= dev
TEST_BIN      ?= ./$(TARGET)

# Derive object files from shared lib sources and tool sources
SHARED_LIB_OBJS = $(LIB_SRCS:%.asm=$(BUILD)/shared_%.o)
TOOL_OBJS       = $(patsubst %.asm,$(BUILD)/%.o,$(notdir $(TOOL_SRCS)))

.PHONY: all dev release clean test bench sizes

all: dev

$(BUILD):
	mkdir -p $(BUILD)

# Pattern rule: assemble shared lib .asm -> .o (from ../../lib/)
$(BUILD)/shared_%.o: $(SHARED_LIB_DIR)/%.asm | $(BUILD)
	$(NASM) $(NASMFLAGS) $< -o $@

# Pattern rule: assemble tool .asm -> .o
$(BUILD)/%.o: tools/%.asm | $(BUILD)
	$(NASM) $(NASMFLAGS) $< -o $@

# Dev build — modular, fast iteration
dev: $(TOOL_SRCS) $(SHARED_LIB_OBJS) | $(BUILD)
	$(NASM) $(NASMFLAGS) $(TOOL_SRCS) -o $(BUILD)/$(TARGET).o
	$(LD) $(LDFLAGS) $(BUILD)/$(TARGET).o $(SHARED_LIB_OBJS) -o $(TARGET)

# Release build — unified file, nasm -f bin, no linker
release: $(UNIFIED_SRC)
	nasm -f bin $(UNIFIED_SRC) -o $(TARGET)_release
	chmod +x $(TARGET)_release

clean:
	rm -rf $(BUILD) $(TARGET) $(TARGET)_release

test: $(TEST_DEP)
	bash tests/run_tests.sh $(TEST_BIN)

bench: dev
	@echo "=== Benchmark ==="

sizes:
	@echo "=== Binary sizes ==="
	@ls -la $(TARGET) $(TARGET)_release 2>/dev/null || true
	@echo "--- Sections ---"
	@size $(TARGET) 2>/dev/null || true
