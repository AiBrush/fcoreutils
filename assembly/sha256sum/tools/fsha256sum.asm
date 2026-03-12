; fsha256sum.asm — GNU-compatible sha256sum in x86-64 Linux assembly
;
; Implements the full SHA-256 hash algorithm (FIPS 180-2) with:
;   - All GNU sha256sum flags (-b, -c, -t, -w, -z, --tag, --quiet, --status, --strict, --ignore-missing)
;   - Proper filename escaping (backslash, newline)
;   - Check mode with BSD and standard format parsing
;   - SIGPIPE handling, EINTR retry, partial write handling
;   - 64KB I/O buffers for high throughput
;
; This is the modular version that uses include files.
; For the self-contained binary, see unified/fsha256sum_unified.asm

%include "include/linux.inc"
%include "include/macros.inc"

section .text
global _start

; SHA-256 round constants K[0..63]
section .rodata
align 16
sha256_K:
    dd 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5
    dd 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
    dd 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3
    dd 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
    dd 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc
    dd 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
    dd 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7
    dd 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
    dd 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13
    dd 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
    dd 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3
    dd 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
    dd 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5
    dd 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
    dd 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208
    dd 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2

hex_digits: db "0123456789abcdef"

; NOTE: This file is the modular source layout for reference/development.
; The actual buildable binary is unified/fsha256sum_unified.asm which
; is fully self-contained (no linker, no libc, builds with nasm -f bin).
