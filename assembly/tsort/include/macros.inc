; macros.inc — Reusable assembly macros

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

; OPEN file: %1=path, %2=flags, %3=mode
%macro OPEN 3
    mov     rax, SYS_OPEN
    mov     rdi, %1
    mov     rsi, %2
    mov     rdx, %3
    syscall
%endmacro

; CLOSE file: %1=fd
%macro CLOSE 1
    mov     rax, SYS_CLOSE
    mov     rdi, %1
    syscall
%endmacro

; FSTAT: %1=fd, %2=stat_buf
%macro FSTAT 2
    mov     rax, SYS_FSTAT
    mov     rdi, %1
    mov     rsi, %2
    syscall
%endmacro
