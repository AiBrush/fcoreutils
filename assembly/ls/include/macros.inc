; macros.inc — Reusable assembly macros for fls
%include "include/linux.inc"

%macro WRITE 3
    mov     rax, SYS_WRITE
    mov     rdi, %1
    mov     rsi, %2
    mov     rdx, %3
    syscall
%endmacro

%macro EXIT 1
    mov     rax, SYS_EXIT
    mov     rdi, %1
    syscall
%endmacro

%macro READ 3
    mov     rax, SYS_READ
    mov     rdi, %1
    mov     rsi, %2
    mov     rdx, %3
    syscall
%endmacro

; FSTAT: %1=fd, %2=stat_buf
%macro FSTAT 2
    mov     rax, SYS_FSTAT
    mov     rdi, %1
    mov     rsi, %2
    syscall
%endmacro

; LSTAT: %1=path, %2=stat_buf
%macro LSTAT 2
    mov     rax, SYS_LSTAT
    mov     rdi, %1
    mov     rsi, %2
    syscall
%endmacro
