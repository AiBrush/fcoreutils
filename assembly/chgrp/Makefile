# chgrp — GNU-compatible group change in x86-64 assembly
TARGET    = fchgrp
LIB_SRCS  =
UNIFIED_SRC = unified/fchgrp_unified.asm

include ../Makefile.inc

# Override dev to build from unified since no tools/ dir
dev: $(UNIFIED_SRC)
	$(NASM) -f bin $(UNIFIED_SRC) -o $(TARGET)
	chmod +x $(TARGET)
