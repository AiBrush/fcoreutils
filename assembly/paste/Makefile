# paste — Makefile (uses shared infrastructure)
TARGET      = fpaste
LIB_SRCS    = io.asm
UNIFIED_SRC = unified/fpaste_unified.asm

include ../../Makefile.inc

bench: dev
	@echo "=== Benchmark vs GNU paste ==="
	@echo "--- Generating test data ---"
	@python3 -c "import random; lines = [''.join(random.choices('abcdefghijklmnopqrstuvwxyz', k=50)) + '\n' for _ in range(1000000)]; open('/tmp/fpaste_a.txt','w').writelines(lines); open('/tmp/fpaste_b.txt','w').writelines(lines)"
	@echo "--- Two files (default tab delimiter) ---"
	@hyperfine --warmup 3 'paste /tmp/fpaste_a.txt /tmp/fpaste_b.txt > /dev/null' './fpaste /tmp/fpaste_a.txt /tmp/fpaste_b.txt > /dev/null'
	@echo "--- Serial mode ---"
	@hyperfine --warmup 3 'paste -s /tmp/fpaste_a.txt > /dev/null' './fpaste -s /tmp/fpaste_a.txt > /dev/null'
	@rm -f /tmp/fpaste_a.txt /tmp/fpaste_b.txt
