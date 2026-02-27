.include "include/linux.inc"

# WRITE fd, buf, len
.macro WRITE fd, buf, len
    mov     rax, SYS_WRITE
    mov     rdi, \fd
    lea     rsi, [\buf]
    mov     rdx, \len
    syscall
.endm

# EXIT code
.macro EXIT code
    mov     rax, SYS_EXIT
    mov     rdi, \code
    syscall
.endm
