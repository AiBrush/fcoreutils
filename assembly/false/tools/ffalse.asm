; ffalse.asm — exit with status 1
;
; GNU false ignores ALL arguments and always exits with code 1.
; Even --help and --version exit 1 (unlike true which exits 0).
; We skip --help/--version per project convention.

%include "include/linux.inc"

extern asm_exit

global _start

section .text

_start:
    ; false: ignore all arguments, exit with code 1
    mov     edi, 1              ; exit code 1
    call    asm_exit

; Non-executable stack
section .note.GNU-stack noalloc noexec nowrite progbits
