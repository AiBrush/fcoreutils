; ============================================================
; farch_unified.asm — GNU-compatible 'arch' command
; Builds with: nasm -f bin farch_unified.asm -o farch
;
; arch: Print machine hardware name (equivalent to uname -m).
;
; Register allocation:
;   r14d = argc, r15 = argv
;   r12  = current argument pointer (for error messages)
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE       1
%define SYS_UNAME      63
%define SYS_EXIT       60
%define SYS_RT_SIGPROCMASK 14

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13

%define BSS_ADDR    0x500000
%define BSS_SIZE    4096
%define UTSNAME_BUF BSS_ADDR          ; 390 bytes for struct utsname

; struct utsname field offsets (each field is 65 bytes, NUL-terminated)
%define UTS_MACHINE   260

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
    dw 64, 56, 3, 64, 0, 0

; --- Program Headers ---
phdr:
    ; PT_LOAD: code + data (R+X)
    dd 1, 5
    dq 0, $$, $$, file_size, file_size, 0x200000

    ; PT_LOAD: BSS (R+W)
    dd 1, 6
    dq 0, BSS_ADDR, BSS_ADDR, 0, BSS_SIZE, 0x200000

    ; PT_GNU_STACK (NX)
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

    ; If argc == 1, just print architecture
    cmp     r14d, 1
    jle     .run_main

    ; argc >= 2: examine argv[1]
    mov     r12, [r15 + 8]      ; r12 = argv[1]

    ; Check if first byte is '-'
    movzx   eax, byte [r12]
    cmp     al, '-'
    jne     .extra_operand

    ; Starts with '-'. Check second byte.
    movzx   eax, byte [r12 + 1]
    test    al, al
    jz      .extra_operand      ; Just "-" alone -> extra operand

    cmp     al, '-'
    jne     .invalid_short_opt  ; Single dash + char -> invalid option

    ; Starts with '--'. Check third byte.
    movzx   eax, byte [r12 + 2]
    test    al, al
    jz      .handle_dashdash    ; Just "--" -> end of options

    ; Long option: compare with --help
    mov     rdi, r12
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .print_help

    ; Compare with --version
    mov     rdi, r12
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .print_version

    ; Unrecognized long option
    jmp     .unrecognized_option

; -- Handle "--" (end of options) --
.handle_dashdash:
    ; If argc == 2, just "--" -> print architecture
    cmp     r14d, 2
    jle     .run_main

    ; argc > 2: argv[2] is an extra operand
    mov     r12, [r15 + 16]     ; argv[2]
    jmp     .extra_operand

; -- Print help --
.print_help:
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

; -- Print version --
.print_version:
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

; -- Error: unrecognized option (--something) --
.unrecognized_option:
    ; "arch: unrecognized option '--something'\n"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err

    mov     rsi, str_unrecog
    mov     edx, str_unrecog_len
    call    do_write_err

    ; Write the argument itself
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    do_write_err

    ; Write suffix: "'\n"
    mov     rsi, str_sq_nl
    mov     edx, str_sq_nl_len
    call    do_write_err

    ; Write: "Try 'arch --help' for more information.\n"
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err

    mov     edi, 1
    jmp     do_exit

; -- Error: invalid option (short -X) --
.invalid_short_opt:
    ; "arch: invalid option -- 'X'\n"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err

    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    do_write_err

    ; Write only the single char after '-'
    lea     rsi, [r12 + 1]
    mov     edx, 1
    call    do_write_err

    ; Write suffix: "'\n"
    mov     rsi, str_sq_nl
    mov     edx, str_sq_nl_len
    call    do_write_err

    ; Write: "Try 'arch --help' for more information.\n"
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err

    mov     edi, 1
    jmp     do_exit

; -- Error: extra operand --
.extra_operand:
    ; "arch: extra operand \xe2\x80\x98foo\xe2\x80\x99\n"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err

    mov     rsi, str_extra
    mov     edx, str_extra_len
    call    do_write_err

    ; Write left curly quote
    mov     rsi, str_lquote
    mov     edx, str_lquote_len
    call    do_write_err

    ; Write the operand
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    do_write_err

    ; Write right curly quote + newline
    mov     rsi, str_rquote_nl
    mov     edx, str_rquote_nl_len
    call    do_write_err

    ; Write: "Try 'arch --help' for more information.\n"
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err

    mov     edi, 1
    jmp     do_exit

; -- Main: print machine architecture --
.run_main:
    ; Call uname() syscall
    mov     eax, SYS_UNAME
    mov     rdi, UTSNAME_BUF
    syscall
    test    rax, rax
    js      .uname_failed

    ; Get pointer to machine field and compute length
    lea     rdi, [UTSNAME_BUF + UTS_MACHINE]
    call    str_len
    mov     edx, eax

    ; Write machine name
    mov     edi, STDOUT
    lea     rsi, [UTSNAME_BUF + UTS_MACHINE]
    call    do_write

    ; Write newline
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write

    ; Exit 0
    xor     edi, edi
    jmp     do_exit

.uname_failed:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_uname_fail
    mov     edx, str_uname_fail_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; ============================================================
; Utility functions
; ============================================================
do_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4             ; -EINTR: retry
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
    db "Usage: arch [OPTION]...", 10
    db "Print machine architecture.", 10
    db 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/arch>", 10
    db "or available locally via: info '(coreutils) arch invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "arch (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by David MacKenzie and Karel Zak.", 10
str_version_len equ $ - str_version

str_prefix:      db "arch: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_extra:       db "extra operand "
str_extra_len    equ $ - str_extra
str_sq_nl:       db "'", 10
str_sq_nl_len    equ $ - str_sq_nl
str_try:         db "Try 'arch --help' for more information.", 10
str_try_len      equ $ - str_try
str_uname_fail:  db "cannot get system information", 10
str_uname_fail_len equ $ - str_uname_fail
; @@DATA_END@@

str_newline:     db 10

; Unicode curly quotes for extra-operand error (U+2018 / U+2019)
str_lquote:      db 0xe2, 0x80, 0x98
str_lquote_len   equ $ - str_lquote
str_rquote_nl:   db 0xe2, 0x80, 0x99, 10
str_rquote_nl_len equ $ - str_rquote_nl

str_help_flag:     db "--help", 0
str_version_flag:  db "--version", 0

file_size equ $ - $$
