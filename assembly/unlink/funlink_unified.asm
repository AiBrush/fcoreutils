; ============================================================
; funlink_unified.asm — GNU-compatible 'unlink' command
; Builds with: nasm -f bin funlink_unified.asm -o funlink
;
; unlink: Call the unlink function to remove the specified FILE.
; Usage: unlink FILE
;
; Register allocation:
;   r14d = argc, r15 = argv
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE       1
%define SYS_UNLINK     87
%define SYS_EXIT       60
%define SYS_RT_SIGPROCMASK 14

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13

; --- ELF Header (64 bytes) ---
ehdr:
    db 0x7f, 'E','L','F'
    db 2, 1, 1, 0
    dq 0
    dw 2, 0x3e
    dd 1
    dq _start
    dq phdr - $$
    dq 0
    dd 0
    dw 64, 56, 2, 64, 0, 0

; --- Program Header: PT_LOAD ---
phdr:
    dd 1, 5
    dq 0, $$, $$, file_size, file_size, 0x200000

; --- Program Header: PT_GNU_STACK (NX) ---
    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 0x10

; ============================================================
; Code
; ============================================================
_start:
    ; Block SIGPIPE
    sub     rsp, 16
    mov     qword [rsp], 0
    bts     qword [rsp], SIGPIPE
    mov     eax, SYS_RT_SIGPROCMASK
    mov     edi, SIG_BLOCK
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    ; Save argc/argv
    mov     r14d, [rsp]         ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Check for --help and --version (only if argc == 2)
    cmp     r14d, 2
    jne     .check_argc
    mov     rdi, [r15 + 8]      ; argv[1]
    cmp     byte [rdi], '-'
    jne     .check_argc
    cmp     byte [rdi + 1], '-'
    jne     .check_argc
    ; Check --help
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .show_help
    mov     rdi, [r15 + 8]
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .show_version

.check_argc:
    ; unlink requires exactly 2 args (argv[0], FILE)
    cmp     r14d, 1
    je      .err_missing_operand
    cmp     r14d, 2
    je      .do_unlink
    ; Too many args: extra operand argv[2]
    jmp     .err_extra_operand

.do_unlink:
    ; unlink(argv[1])
    mov     rdi, [r15 + 8]      ; FILE
    mov     eax, SYS_UNLINK
    syscall
    test    rax, rax
    js      .unlink_failed
    ; Success
    xor     edi, edi
    jmp     do_exit

.unlink_failed:
    ; rax = negative errno
    neg     rax                 ; now rax = positive errno
    mov     r12, rax            ; save errno

    ; "unlink: cannot unlink '"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_unlink
    mov     edx, str_cannot_unlink_len
    call    do_write_err
    ; filename (argv[1])
    mov     rdi, [r15 + 8]
    call    str_len
    mov     edx, eax
    mov     rsi, [r15 + 8]
    call    do_write_err
    ; "': "
    mov     rsi, str_sq_colon
    mov     edx, str_sq_colon_len
    call    do_write_err

    ; Determine error message from errno
    cmp     r12, 2              ; ENOENT
    je      .emit_enoent
    cmp     r12, 1              ; EPERM
    je      .emit_eperm
    cmp     r12, 13             ; EACCES
    je      .emit_eacces
    cmp     r12, 21             ; EISDIR
    je      .emit_eisdir
    ; Default: unknown error
    mov     rsi, str_err_unknown
    mov     edx, str_err_unknown_len
    call    do_write_err
    jmp     .unlink_error_exit

.emit_enoent:
    mov     rsi, str_err_enoent
    mov     edx, str_err_enoent_len
    call    do_write_err
    jmp     .unlink_error_exit
.emit_eperm:
    mov     rsi, str_err_eperm
    mov     edx, str_err_eperm_len
    call    do_write_err
    jmp     .unlink_error_exit
.emit_eacces:
    mov     rsi, str_err_eacces
    mov     edx, str_err_eacces_len
    call    do_write_err
    jmp     .unlink_error_exit
.emit_eisdir:
    mov     rsi, str_err_eisdir
    mov     edx, str_err_eisdir_len
    call    do_write_err

.unlink_error_exit:
    mov     edi, 1
    jmp     do_exit

.show_help:
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.show_version:
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.err_missing_operand:
    ; "unlink: missing operand\n"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing
    mov     edx, str_missing_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.err_extra_operand:
    ; "unlink: extra operand 'FILE2'\n"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_extra
    mov     edx, str_extra_len
    call    do_write_err
    ; argv[2]
    mov     rdi, [r15 + 16]
    call    str_len
    mov     edx, eax
    mov     rsi, [r15 + 16]
    call    do_write_err
    mov     rsi, str_csq_nl
    mov     edx, 4
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; ============================================================
; Utility functions
; ============================================================
do_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      do_write
    ret

do_write_err:
    mov     edi, STDERR
    jmp     do_write

do_exit:
    mov     eax, SYS_EXIT
    syscall

str_len:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     eax
    jmp     .sl_loop
.sl_done:
    ret

; str_eq: compare two NUL-terminated strings
; rdi = s1, rsi = s2; returns eax: 1=equal, 0=not equal
str_eq:
    xor     r8d, r8d
.se_loop:
    movzx   eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    cmp     al, dl
    jne     .se_ne
    test    al, al
    jz      .se_eq
    inc     r8d
    jmp     .se_loop
.se_eq:
    mov     eax, 1
    ret
.se_ne:
    xor     eax, eax
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: unlink FILE", 10
    db "  or:  unlink OPTION", 10
    db "Call the unlink function to remove the specified FILE.", 10, 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/unlink>", 10
    db "or available locally via: info '(coreutils) unlink invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "unlink (GNU coreutils) 9.4", 10
    db "Copyright (C) 2023 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Michael Stone.", 10
str_version_len equ $ - str_version

str_prefix:      db "unlink: "
str_prefix_len   equ $ - str_prefix
str_extra:       db "extra operand ", 0xe2, 0x80, 0x98
str_extra_len    equ $ - str_extra
str_missing:     db "missing operand", 10
str_missing_len  equ $ - str_missing
str_cannot_unlink: db "cannot unlink '"
str_cannot_unlink_len equ $ - str_cannot_unlink
str_sq_colon:    db "': "
str_sq_colon_len equ $ - str_sq_colon
str_sq_nl:       db "'", 10
str_csq_nl:      db 0xe2, 0x80, 0x99, 10
str_try:         db "Try 'unlink --help' for more information.", 10
str_try_len      equ $ - str_try

str_err_enoent:  db "No such file or directory", 10
str_err_enoent_len equ $ - str_err_enoent
str_err_eperm:   db "Operation not permitted", 10
str_err_eperm_len equ $ - str_err_eperm
str_err_eacces:  db "Permission denied", 10
str_err_eacces_len equ $ - str_err_eacces
str_err_eisdir:  db "Is a directory", 10
str_err_eisdir_len equ $ - str_err_eisdir
str_err_unknown: db "Unknown error", 10
str_err_unknown_len equ $ - str_err_unknown
; @@DATA_END@@

str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0

file_size equ $ - $$
