; fsha384sum.asm — GNU-compatible sha384sum in x86-64 Linux assembly
;
; Implements the full SHA-384 hash algorithm (FIPS 180-4) with:
;   - All GNU sha384sum flags (-b, -c, -t, -w, -z, --tag, --quiet, --status, --strict, --ignore-missing)
;   - Proper filename escaping (backslash, newline)
;   - Check mode with BSD and standard format parsing
;   - SIGPIPE handling, EINTR retry, partial write handling
;   - 64KB I/O buffers for high throughput
;
; SHA-384 is a truncated SHA-512 with different initial hash values.
; Output: first 384 bits (48 bytes, 96 hex chars).
;
; This is the modular version. For the self-contained flat binary, see:
;   unified/fsha384sum_unified.asm
;
; Build (unified):
;   nasm -f bin unified/fsha384sum_unified.asm -o fsha384sum && chmod +x fsha384sum

%include "include/linux.inc"
%include "include/macros.inc"

; NOTE: The actual implementation is in unified/fsha384sum_unified.asm
; This file exists for project structure consistency.
