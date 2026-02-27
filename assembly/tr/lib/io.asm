; io.asm — Shared I/O functions for assembly tools
; Handles EINTR, partial writes, and basic file operations

%include "include/linux.inc"

global asm_write
global asm_write_all
global asm_read
global asm_exit

section .text

; asm_write(rdi=fd, rsi=buf, rdx=len) -> rax=bytes_written
; Retries on EINTR
asm_write:
.retry:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, EINTR
    je      .retry
    ret

; asm_write_all(rdi=fd, rsi=buf, rdx=len) -> rax=0 success, -1 error
; Handles partial writes + EINTR
asm_write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi            ; fd
    mov     r12, rsi            ; buf
    mov     r13, rdx            ; remaining
.loop:
    test    r13, r13
    jle     .success
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, EINTR
    je      .loop               ; EINTR — retry
    test    rax, rax
    js      .error              ; negative = error
    add     r12, rax
    sub     r13, rax
    jmp     .loop
.success:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.error:
    pop     r13
    pop     r12
    pop     rbx
    ret                         ; rax already has negative error code

; asm_read(rdi=fd, rsi=buf, rdx=len) -> rax=bytes_read
; Retries on EINTR
asm_read:
.retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, EINTR
    je      .retry
    ret

; asm_exit(rdi=code) — does not return
asm_exit:
    mov     rax, SYS_EXIT
    syscall

section .note.GNU-stack noalloc noexec nowrite progbits
