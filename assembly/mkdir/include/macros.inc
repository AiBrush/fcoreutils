; Macros for mkdir
%macro WRITE 3
    mov rax, SYS_WRITE
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    syscall
%endmacro

%macro EXIT 1
    mov rax, SYS_EXIT
    mov rdi, %1
    syscall
%endmacro
