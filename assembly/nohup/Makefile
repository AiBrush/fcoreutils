NASM ?= nasm
TOOL = fnohup

.PHONY: all clean dev release test

all: $(TOOL)

$(TOOL): unified/fnohup_unified.asm
	$(NASM) -f bin $< -o $@
	chmod +x $@

dev: $(TOOL)

release: $(TOOL)
	cp $(TOOL) $(TOOL)_release

clean:
	rm -f $(TOOL) $(TOOL)_release

test: $(TOOL)
	bash tests/run_tests.sh
