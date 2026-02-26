NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I include/
BUILD     = build
LDFLAGS   = --gc-sections -n

# Shared library objects
LIB_SRC   = $(wildcard lib/*.asm)
LIB_OBJ   = $(patsubst lib/%.asm,$(BUILD)/lib/%.o,$(LIB_SRC))

# Tool targets
TOOLS     = $(patsubst tools/%.asm,%,$(wildcard tools/*.asm))

.PHONY: all clean test

all: $(BUILD) $(TOOLS)

$(BUILD):
	mkdir -p $(BUILD)/lib $(BUILD)/tools

# Compile shared libs
$(BUILD)/lib/%.o: lib/%.asm include/*.inc | $(BUILD)
	$(NASM) $(NASMFLAGS) $< -o $@

# Compile + link each tool
$(TOOLS): %: tools/%.asm $(LIB_OBJ) | $(BUILD)
	$(NASM) $(NASMFLAGS) $< -o $(BUILD)/tools/$@.o
	$(LD) $(LDFLAGS) $(BUILD)/tools/$@.o $(LIB_OBJ) -o $@

# Release build (unified, no linker)
release-%: unified/%_unified.asm
	nasm -f bin $< -o $*
	chmod +x $*

clean:
	rm -rf $(BUILD) $(TOOLS)
