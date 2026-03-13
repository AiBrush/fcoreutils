; I/O library for mv (modular build)
section .text
global asm_write, asm_write_stdout, asm_write_err, asm_exit

%define SYS_WRITE 1
%define SYS_EXIT  60
%define STDOUT    1
%define STDERR    2

asm_write:
.retry:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      .retry
    ret

asm_write_stdout:
    mov     rdi, STDOUT
    jmp     asm_write

asm_write_err:
    mov     rdi, STDERR
    jmp     asm_write

asm_exit:
    mov     rax, SYS_EXIT
    syscall
