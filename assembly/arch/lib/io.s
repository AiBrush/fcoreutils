.intel_syntax noprefix
.section .note.GNU-stack,"",@progbits
.include "include/linux.inc"

.global asm_write
.global asm_exit
.global asm_write_err
.global asm_write_stdout

.section .text

# asm_write(rdi=fd, rsi=buf, rdx=len) -> rax=bytes or negative errno
# Retries on EINTR automatically
asm_write:
.Lretry_write:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4         # -EINTR?
    je      .Lretry_write
    ret

# asm_write_stdout(rsi=buf, rdx=len) - writes to stdout
asm_write_stdout:
    mov     rdi, STDOUT
    jmp     asm_write

# asm_write_err(rsi=buf, rdx=len) - writes to stderr
asm_write_err:
    mov     rdi, STDERR
    jmp     asm_write

# asm_exit(rdi=code) - never returns
asm_exit:
    mov     rax, SYS_EXIT
    syscall
