; fsha1sum.asm — GNU-compatible sha1sum in x86-64 Linux assembly
;
; Implements the full SHA-1 hash algorithm (FIPS-180-1) with:
;   - All GNU sha1sum flags (-b, -c, -t, -w, -z, --tag, --quiet, --status, --strict, --ignore-missing)
;   - Proper filename escaping (backslash, newline)
;   - Check mode with BSD and standard format parsing
;   - SIGPIPE handling, EINTR retry, partial write handling
;   - 64KB I/O buffers for high throughput
;
; This is the modular version. For the self-contained flat binary, see:
;   unified/fsha1sum_unified.asm
;
; Build (unified):
;   nasm -f bin unified/fsha1sum_unified.asm -o fsha1sum && chmod +x fsha1sum

%include "include/linux.inc"
%include "include/macros.inc"

; NOTE: The actual implementation is in unified/fsha1sum_unified.asm
; This file exists for project structure consistency.
