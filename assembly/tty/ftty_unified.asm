; ============================================================
; ftty_unified.asm — AUTO-GENERATED unified file
; tty(1) implementation for x86_64 Linux
; Build: nasm -f bin ftty_unified.asm -o ftty_release && chmod +x ftty_release
; ============================================================

BITS 64
ORG 0x400000

; ── Syscall numbers and constants ────────────────────────────
%define SYS_WRITE       1
%define SYS_IOCTL      16
%define SYS_EXIT       60
%define SYS_READLINK   89

%define TCGETS      0x5401

%define STDIN           0
%define STDOUT          1
%define STDERR          2

%define PATH_MAX     4096
%define BSS_SIZE     4160       ; 64 (termios) + 4096 (ttyname)

; ============================================================
; ELF64 Header (64 bytes)
; ============================================================
ehdr:
    db 0x7f, 'E','L','F'       ; magic
    db 2                        ; 64-bit
    db 1                        ; little endian
    db 1                        ; ELF version
    db 0                        ; OS/ABI: System V
    dq 0                        ; padding
    dw 2                        ; ET_EXEC
    dw 0x3e                     ; x86_64
    dd 1                        ; ELF version
    dq _start                   ; entry point
    dq phdr - $$                ; program header offset
    dq 0                        ; section header offset (none)
    dd 0                        ; flags
    dw 64                       ; ELF header size
    dw phdr_size                ; program header entry size
    dw 2                        ; 2 program headers
    dw 64                       ; section header entry size
    dw 0                        ; section header count
    dw 0                        ; section name index

; ============================================================
; Program Header — single PT_LOAD (RWX), MemSiz > FileSiz for BSS
; ============================================================
phdr:
    dd 1                        ; PT_LOAD
    dd 7                        ; PF_R | PF_W | PF_X
    dq 0                        ; offset in file
    dq $$                       ; virtual address
    dq $$                       ; physical address
    dq file_size                ; file size
    dq file_size + BSS_SIZE     ; memory size (includes BSS)
    dq 0x200000                 ; alignment
phdr_size equ $ - phdr

; PT_GNU_STACK — mark stack as non-executable
phdr_stack:
    dd 0x6474e551               ; PT_GNU_STACK
    dd 6                        ; PF_R | PF_W (no PF_X)
    dq 0                        ; offset
    dq 0                        ; virtual address
    dq 0                        ; physical address
    dq 0                        ; file size
    dq 0                        ; memory size
    dq 0x10                     ; alignment

; ============================================================
; Code section
; ============================================================
_start:
    ; Get argc and argv from stack
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv

    ; r12 = silent flag (0 = not silent)
    xor     r12, r12

    ; Parse arguments
    cmp     r14, 1
    jle     .run_main

    mov     r13, 1              ; i = 1

.arg_loop:
    cmp     r13, r14
    jge     .run_main

    mov     rsi, [r15 + r13*8]  ; argv[i]

    ; Check if arg starts with '-'
    cmp     byte [rsi], '-'
    jne     .err_extra_operand

    ; Check if it's just "-"
    cmp     byte [rsi + 1], 0
    je      .err_extra_operand

    ; Check if starts with '--'
    cmp     byte [rsi + 1], '-'
    je      .check_long_opt

    ; Short options
    jmp     .parse_short_opts

.check_long_opt:
    ; Check if it's exactly "--" (end of options marker)
    cmp     byte [rsi + 2], 0
    je      .end_of_opts

    ; Check --help
    mov     rdi, rsi
    lea     rsi, [rel str_opt_help]
    call    _strcmp
    mov     rsi, rdi
    test    rax, rax
    jz      .do_help

    ; Check --version
    mov     rdi, rsi
    lea     rsi, [rel str_opt_version]
    call    _strcmp
    mov     rsi, rdi
    test    rax, rax
    jz      .do_version

    ; Check --silent
    mov     rdi, rsi
    lea     rsi, [rel str_opt_silent]
    call    _strcmp
    mov     rsi, rdi
    test    rax, rax
    jz      .set_silent

    ; Check --quiet
    mov     rdi, rsi
    lea     rsi, [rel str_opt_quiet]
    call    _strcmp
    mov     rsi, rdi
    test    rax, rax
    jz      .set_silent

    ; Unrecognized long option
    mov     rsi, rdi
    jmp     .err_unrecognized_opt

.parse_short_opts:
    mov     rbx, rsi
    inc     rbx                 ; skip '-'

.short_opt_loop:
    movzx   eax, byte [rbx]
    test    al, al
    jz      .next_arg

    cmp     al, 's'
    je      .short_s

    ; Invalid short option char
    mov     r8b, al
    jmp     .err_invalid_short_opt

.short_s:
    mov     r12, 1
    inc     rbx
    jmp     .short_opt_loop

.set_silent:
    mov     r12, 1
    jmp     .next_arg

.next_arg:
    inc     r13
    jmp     .arg_loop

; Handle "--" end-of-options: remaining args are operands
.end_of_opts:
    inc     r13
    cmp     r13, r14
    jge     .run_main           ; no more args after --, proceed normally
    ; First arg after -- is an extra operand
    mov     rsi, [r15 + r13*8]
    jmp     .err_extra_operand

; ── Help ─────────────────────────────────────────────────────
.do_help:
    mov     rdi, STDOUT
    lea     rsi, [rel str_help]
    mov     rdx, str_help_len
    call    _write
    xor     rdi, rdi
    jmp     _exit

; ── Version ──────────────────────────────────────────────────
.do_version:
    mov     rdi, STDOUT
    lea     rsi, [rel str_version]
    mov     rdx, str_version_len
    call    _write
    xor     rdi, rdi
    jmp     _exit

; ── Main: check if stdin is a tty ────────────────────────────
.run_main:
    ; ioctl(STDIN, TCGETS, termios_buf)
    mov     rax, SYS_IOCTL
    mov     rdi, STDIN
    mov     rsi, TCGETS
    lea     rdx, [rel termios_buf]
    syscall

    test    rax, rax
    jnz     .not_a_tty

    ; stdin IS a tty
    cmp     r12, 1
    je      .exit_success

    ; readlink("/proc/self/fd/0", buf, PATH_MAX-1)
    mov     rax, SYS_READLINK
    lea     rdi, [rel str_proc_fd0]
    lea     rsi, [rel ttyname_buf]
    mov     rdx, PATH_MAX - 1
    syscall

    test    rax, rax
    jle     .not_a_tty

    ; Append newline
    lea     rdi, [rel ttyname_buf]
    mov     byte [rdi + rax], 10
    inc     rax

    ; Write tty name
    mov     rdx, rax
    mov     rsi, rdi
    mov     rdi, STDOUT
    call    _write

.exit_success:
    xor     rdi, rdi
    jmp     _exit

.not_a_tty:
    cmp     r12, 1
    je      .exit_not_tty

    mov     rdi, STDOUT
    lea     rsi, [rel str_not_a_tty]
    mov     rdx, str_not_a_tty_len
    call    _write

.exit_not_tty:
    mov     rdi, 1
    jmp     _exit

; ── Error: invalid short option ──────────────────────────────
.err_invalid_short_opt:
    mov     rdi, STDERR
    lea     rsi, [rel str_err_prefix]
    mov     rdx, str_err_prefix_len
    call    _write

    mov     rdi, STDERR
    lea     rsi, [rel str_err_invalid_opt]
    mov     rdx, str_err_invalid_opt_len
    call    _write

    ; Write the char + quote + newline using stack
    push    0                   ; alignment + space
    mov     byte [rsp], r8b
    mov     byte [rsp + 1], 0x27
    mov     byte [rsp + 2], 10
    mov     rsi, rsp
    mov     rdi, STDERR
    mov     rdx, 3
    call    _write
    pop     rax

    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    _write

    mov     rdi, 2
    jmp     _exit

; ── Error: unrecognized long option ──────────────────────────
.err_unrecognized_opt:
    mov     rbx, rsi

    mov     rdi, STDERR
    lea     rsi, [rel str_err_prefix]
    mov     rdx, str_err_prefix_len
    call    _write

    mov     rdi, STDERR
    lea     rsi, [rel str_err_unrecognized]
    mov     rdx, str_err_unrecognized_len
    call    _write

    mov     rdi, rbx
    call    _strlen
    mov     rdx, rax
    mov     rsi, rbx
    mov     rdi, STDERR
    call    _write

    mov     rdi, STDERR
    lea     rsi, [rel str_err_quote_nl]
    mov     rdx, str_err_quote_nl_len
    call    _write

    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    _write

    mov     rdi, 2
    jmp     _exit

; ── Error: extra operand ─────────────────────────────────────
.err_extra_operand:
    mov     rbx, rsi

    mov     rdi, STDERR
    lea     rsi, [rel str_err_prefix]
    mov     rdx, str_err_prefix_len
    call    _write

    mov     rdi, STDERR
    lea     rsi, [rel str_err_extra_operand]
    mov     rdx, str_err_extra_operand_len
    call    _write

    mov     rdi, rbx
    call    _strlen
    mov     rdx, rax
    mov     rsi, rbx
    mov     rdi, STDERR
    call    _write

    mov     rdi, STDERR
    lea     rsi, [rel str_err_quote_nl_unicode]
    mov     rdx, str_err_quote_nl_unicode_len
    call    _write

    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    _write

    mov     rdi, 2
    jmp     _exit

; ============================================================
; Inlined library functions
; ============================================================

; _write(rdi=fd, rsi=buf, rdx=len) -> rax
_write:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4             ; -EINTR
    je      _write
    ret

; _exit(rdi=code) — never returns
_exit:
    mov     rax, SYS_EXIT
    syscall

; _strlen(rdi=str) -> rax=length
_strlen:
    xor     rax, rax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; _strcmp(rdi=s1, rsi=s2) -> rax: 0 if equal, preserves rdi
_strcmp:
    push    rdi
.sc_loop:
    mov     al, [rdi]
    mov     cl, [rsi]
    cmp     al, cl
    jne     .sc_neq
    test    al, al
    jz      .sc_eq
    inc     rdi
    inc     rsi
    jmp     .sc_loop
.sc_eq:
    xor     rax, rax
    pop     rdi
    ret
.sc_neq:
    movzx   rax, al
    movzx   rcx, cl
    sub     rax, rcx
    pop     rdi
    ret

; ============================================================
; Read-only data
; ============================================================

; @@DATA_START@@
str_help:
    db "Usage: tty [OPTION]...", 10
    db "Print the file name of the terminal connected to standard input.", 10
    db 10
    db "  -s, --silent, --quiet   print nothing, only return an exit status", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/tty>", 10
    db "or available locally via: info '(coreutils) tty invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "tty (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by David MacKenzie.", 10
str_version_len equ $ - str_version

str_not_a_tty:
    db "not a tty", 10
str_not_a_tty_len equ $ - str_not_a_tty

str_err_prefix:
    db "tty: "
str_err_prefix_len equ $ - str_err_prefix

str_err_invalid_opt:
    db "invalid option -- '"
str_err_invalid_opt_len equ $ - str_err_invalid_opt

str_err_unrecognized:
    db "unrecognized option '"
str_err_unrecognized_len equ $ - str_err_unrecognized

str_err_extra_operand:
    db "extra operand ", 0xE2, 0x80, 0x98
str_err_extra_operand_len equ $ - str_err_extra_operand

str_err_quote_nl:
    db "'", 10
str_err_quote_nl_len equ $ - str_err_quote_nl

str_err_quote_nl_unicode:
    db 0xE2, 0x80, 0x99, 10
str_err_quote_nl_unicode_len equ $ - str_err_quote_nl_unicode

str_try_help:
    db "Try 'tty --help' for more information.", 10
str_try_help_len equ $ - str_try_help
; @@DATA_END@@

str_opt_help:
    db "--help", 0
str_opt_version:
    db "--version", 0
str_opt_silent:
    db "--silent", 0
str_opt_quiet:
    db "--quiet", 0

str_proc_fd0:
    db "/proc/self/fd/0", 0

file_size equ $ - $$

; ============================================================
; BSS — zero-initialized memory beyond file_size
; The kernel zeroes memory between file_size and mem_size
; ============================================================
; termios_buf: file_size + 0x400000, 64 bytes
; ttyname_buf: file_size + 0x400000 + 64, PATH_MAX bytes
termios_buf equ $$ + file_size
ttyname_buf equ $$ + file_size + 64
