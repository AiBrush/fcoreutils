%include "include/linux.inc"

global asm_write
global asm_exit
global asm_write_err

section .text

asm_write:
.retry:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      .retry
    ret

asm_write_err:
    mov     rdi, STDERR
    jmp     asm_write

asm_exit:
    mov     rax, SYS_EXIT
    syscall

section .note.GNU-stack noalloc noexec nowrite progbits
