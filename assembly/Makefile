# Top-level Makefile for fcoreutils assembly tools
# Discovers all tool directories and provides aggregate targets

SHELL := /bin/bash

# Discover all tool directories (those with a Makefile, excluding lib/ and tests/)
TOOL_DIRS := $(sort $(patsubst %/Makefile,%,$(wildcard */Makefile)))

.PHONY: all test clean sizes help $(addprefix tool-,$(TOOL_DIRS))

all:
	@echo "Building all $(words $(TOOL_DIRS)) tools..."
	@fail=0; \
	for dir in $(TOOL_DIRS); do \
		printf "  %-20s " "$$dir"; \
		if $(MAKE) -C $$dir dev --no-print-directory 2>/dev/null; then \
			echo "OK"; \
		else \
			echo "FAIL"; \
			fail=$$((fail + 1)); \
		fi; \
	done; \
	echo ""; \
	echo "Build complete: $$(($(words $(TOOL_DIRS)) - fail))/$(words $(TOOL_DIRS)) succeeded"; \
	[ $$fail -eq 0 ]

test:
	@echo "Testing all $(words $(TOOL_DIRS)) tools..."
	@pass=0; fail=0; skip=0; \
	for dir in $(TOOL_DIRS); do \
		printf "  %-20s " "$$dir"; \
		if [ -f "$$dir/tests/run_tests.sh" ]; then \
			if $(MAKE) -C $$dir test --no-print-directory 2>/dev/null; then \
				echo "PASS"; \
				pass=$$((pass + 1)); \
			else \
				echo "FAIL"; \
				fail=$$((fail + 1)); \
			fi; \
		else \
			echo "SKIP (no tests)"; \
			skip=$$((skip + 1)); \
		fi; \
	done; \
	echo ""; \
	echo "Test complete: $$pass passed, $$fail failed, $$skip skipped"; \
	[ $$fail -eq 0 ]

clean:
	@echo "Cleaning all $(words $(TOOL_DIRS)) tools..."
	@for dir in $(TOOL_DIRS); do \
		$(MAKE) -C $$dir clean --no-print-directory 2>/dev/null || true; \
	done
	@echo "Clean complete."

# Build a specific tool: make tool-<name>
$(addprefix tool-,$(TOOL_DIRS)):
	$(MAKE) -C $(patsubst tool-%,%,$@) dev

sizes:
	@echo "=== Binary Sizes ==="
	@printf "%-20s %10s %10s\n" "Tool" "Dev" "Release"
	@printf "%-20s %10s %10s\n" "----" "---" "-------"
	@for dir in $(TOOL_DIRS); do \
		dev=$$(find "$$dir" -maxdepth 1 -name 'f*' -executable -not -name '*_*' -printf '%s' 2>/dev/null || echo "-"); \
		rel=$$(find "$$dir" -maxdepth 1 -name '*_release' -executable -printf '%s' 2>/dev/null || echo "-"); \
		printf "%-20s %10s %10s\n" "$$dir" "$${dev:-"-"}" "$${rel:-"-"}"; \
	done

help:
	@echo "fcoreutils assembly build system"
	@echo ""
	@echo "Targets:"
	@echo "  all          Build all tools (dev mode)"
	@echo "  test         Run tests for all tools"
	@echo "  clean        Clean all build artifacts"
	@echo "  tool-<name>  Build a specific tool (e.g., make tool-seq)"
	@echo "  sizes        Report binary sizes for all tools"
	@echo "  help         Show this help"
	@echo ""
	@echo "Tools: $(TOOL_DIRS)"
