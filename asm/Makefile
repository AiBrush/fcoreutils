NASM      = nasm
LD        = ld
NASMFLAGS = -f elf64 -I include/
BUILD     = build
LDFLAGS   = --gc-sections

# Tool targets
TOOLS     = fmd5sum

.PHONY: all clean test tiny

all: $(BUILD) $(TOOLS)

$(BUILD):
	mkdir -p $(BUILD)/tools

# Compile + link each tool (development build)
fmd5sum: tools/fmd5sum.asm include/*.inc | $(BUILD)
	$(NASM) $(NASMFLAGS) $< -o $(BUILD)/tools/fmd5sum.o
	$(LD) $(LDFLAGS) $(BUILD)/tools/fmd5sum.o -o $@

# Unified minimal binary (no linker)
tiny: fmd5sum_tiny

fmd5sum_tiny: unified/fmd5sum_unified.asm
	$(NASM) -f bin $< -o $@
	chmod +x $@

test: fmd5sum
	TOOL=./fmd5sum bash tests/test_fmd5sum.sh

test-tiny: fmd5sum_tiny
	TOOL=./fmd5sum_tiny bash tests/test_fmd5sum.sh

clean:
	rm -rf $(BUILD) $(TOOLS) fmd5sum_tiny
