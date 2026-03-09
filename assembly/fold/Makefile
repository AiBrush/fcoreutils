NASM = nasm
LD = ld
NASM_FLAGS = -f elf64 -I include/
LD_FLAGS = --gc-sections -n -s

BUILD_DIR = build

TOOL_SRC = tools/ffold.asm
IO_SRC = lib/io.asm

TOOL_OBJ = $(BUILD_DIR)/tools/ffold.o
IO_OBJ = $(BUILD_DIR)/lib/io.o

TARGET = ffold
UNIFIED_SRC = unified/ffold_unified.asm
UNIFIED_TARGET = ffold_tiny

.PHONY: all dev release clean test

all: dev

dev: $(TARGET)

$(TARGET): $(TOOL_OBJ) $(IO_OBJ)
	$(LD) $(LD_FLAGS) $^ -o $@

$(BUILD_DIR)/tools/ffold.o: $(TOOL_SRC) include/linux.inc include/macros.inc
	@mkdir -p $(BUILD_DIR)/tools
	$(NASM) $(NASM_FLAGS) $< -o $@

$(BUILD_DIR)/lib/io.o: $(IO_SRC) include/linux.inc
	@mkdir -p $(BUILD_DIR)/lib
	$(NASM) $(NASM_FLAGS) $< -o $@

release: $(UNIFIED_TARGET)

$(UNIFIED_TARGET): $(UNIFIED_SRC)
	$(NASM) -f bin $< -o $@
	chmod +x $@

clean:
	rm -rf $(BUILD_DIR) $(TARGET) $(UNIFIED_TARGET)

test: dev
	bash tests/run_tests.sh ./$(TARGET)
