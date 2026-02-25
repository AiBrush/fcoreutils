; ftrue.asm — exit with status 0
;
; GNU true ignores ALL arguments (including --help and --version)
; and always exits with code 0, producing no output.

%include "include/linux.inc"

extern asm_exit

global _start

section .text

_start:
    ; true: just exit 0 — ignore everything
    xor     rdi, rdi        ; exit code 0
    call    asm_exit
