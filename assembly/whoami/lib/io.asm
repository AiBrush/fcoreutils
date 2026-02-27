%include "include/linux.inc"

global asm_write
global asm_exit
global asm_write_err
global asm_read
global asm_open
global asm_close

section .text

; asm_write(rdi=fd, rsi=buf, rdx=len) -> rax=bytes or negative errno
; Retries on EINTR automatically
asm_write:
.retry:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4         ; -EINTR?
    je      .retry
    ret

; asm_write_err(rsi=buf, rdx=len) — writes to stderr
asm_write_err:
    mov     rdi, STDERR
    jmp     asm_write

; asm_read(rdi=fd, rsi=buf, rdx=len) -> rax=bytes or negative errno
asm_read:
.retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, -4         ; -EINTR?
    je      .retry
    ret

; asm_open(rdi=path, rsi=flags, rdx=mode) -> rax=fd or negative errno
asm_open:
    mov     rax, SYS_OPEN
    syscall
    ret

; asm_close(rdi=fd) -> rax
asm_close:
    mov     rax, SYS_CLOSE
    syscall
    ret

; asm_exit(rdi=code) — never returns
asm_exit:
    mov     rax, SYS_EXIT
    syscall
