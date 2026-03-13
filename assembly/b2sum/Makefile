ASM = nasm
ASMFLAGS = -f bin
TARGET = fb2sum
SRC = unified/fb2sum_unified.asm

.PHONY: all clean test

all: $(TARGET)

$(TARGET): $(SRC)
	$(ASM) $(ASMFLAGS) $< -o $@
	chmod +x $@

clean:
	rm -f $(TARGET)

test: $(TARGET)
	@echo "=== BLAKE2b Test Vectors ==="
	@echo -n "" | ./$(TARGET) | head -1
	@EXPECTED="786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce"; \
	RESULT=$$(echo -n "" | ./$(TARGET) | cut -d' ' -f1); \
	if [ "$$RESULT" = "$$EXPECTED" ]; then echo "PASS: empty string"; else echo "FAIL: empty string (got $$RESULT)"; fi
	@EXPECTED="ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6886a7e7907d229a9e1e7e21202000e0f3efc86544b9b2d8b4d407b85ca91279c9e48a5840a"; \
	RESULT=$$(echo -n "abc" | ./$(TARGET) | cut -d' ' -f1); \
	if [ "$$RESULT" = "$$EXPECTED" ]; then echo "PASS: abc"; else echo "FAIL: abc (got $$RESULT)"; fi
	@echo "=== Tests Complete ==="
