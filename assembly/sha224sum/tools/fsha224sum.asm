; fsha224sum.asm — GNU-compatible sha224sum in x86-64 Linux assembly
;
; Implements the full SHA-224 hash algorithm (FIPS 180-4) with:
;   - All GNU sha224sum flags (-b, -c, -t, -w, -z, --tag, --quiet, --status, --strict, --ignore-missing)
;   - Proper filename escaping (backslash, newline)
;   - Check mode with BSD and standard format parsing
;   - SIGPIPE handling, EINTR retry, partial write handling
;   - 64KB I/O buffers for high throughput
;
; SHA-224 is a truncated SHA-256 with different initial hash values.
; Output: first 224 bits (28 bytes, 56 hex chars).
;
; This is the modular version. For the self-contained flat binary, see:
;   unified/fsha224sum_unified.asm
;
; Build (unified):
;   nasm -f bin unified/fsha224sum_unified.asm -o fsha224sum && chmod +x fsha224sum

%include "include/linux.inc"
%include "include/macros.inc"

; NOTE: The actual implementation is in unified/fsha224sum_unified.asm
; This file exists for project structure consistency.
