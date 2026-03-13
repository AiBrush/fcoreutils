; ============================================================
; fdirname_unified.asm — GNU-compatible 'dirname' command
; Builds with: nasm -f bin fdirname_unified.asm -o fdirname
;
; dirname: Strip last component from file names.
;
; Register allocation:
;   r14d = argc, r15 = argv, ebx = flags, ecx = arg index
;   r13  = file index during file loop
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE       1
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

    ; Initialize flags
    xor     ebx, ebx            ; flags: bit 1 = -z/--zero
    mov     ecx, 1              ; arg index (start after argv[0])

    ; Parse options
.parse_opts:
    cmp     ecx, r14d
    jge     .err_missing_operand
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .done_opts
    cmp     byte [rdi + 1], 0
    je      .done_opts           ; bare "-" is not an option
    cmp     byte [rdi + 1], '-'
    je      .check_long

    ; Short options: -z (can be combined)
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'z'
    je      .set_zero
    ; Invalid short option
    mov     r13, rdi
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    do_write_err
    mov     rsi, r13
    mov     edx, 1
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.set_zero:
    or      bl, 2
    inc     rdi
    jmp     .short_loop

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
    ; Save arg pointer in r13
    mov     r13, rdi
    push    rcx
    ; Check --help
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_help
    ; Check --version
    mov     rdi, r13
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_version
    ; Check --zero
    mov     rdi, r13
    mov     rsi, str_zero_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_long_zero
    ; Unrecognized long option
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_unrecog
    mov     edx, str_unrecog_len
    call    do_write_err
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    pop     rcx
    mov     edi, 1
    jmp     do_exit

.pop_show_help:
    pop     rcx
    jmp     .show_help
.pop_show_version:
    pop     rcx
    jmp     .show_version
.pop_set_long_zero:
    pop     rcx
    or      bl, 2
    jmp     .next_opt

.double_dash:
    inc     ecx
    jmp     .done_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

.done_opts:
    ; ecx = index of first filename arg
    cmp     ecx, r14d
    jge     .err_missing_operand

    ; Process remaining args as filenames
    mov     r13d, ecx           ; current file index
.file_loop:
    cmp     r13d, r14d
    jge     .exit_ok
    mov     rdi, [r15 + r13*8]
    call    do_dirname
    inc     r13d
    jmp     .file_loop

.exit_ok:
    xor     edi, edi
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

; ============================================================
; do_dirname: process one filename
; Input: rdi = filename string pointer
; Uses: bl flags (bit 1 = -z)
;
; Algorithm:
;   1. If empty string, output "."
;   2. Strip trailing slashes (but keep root /)
;   3. Find last /
;   4. If no /, output "."
;   5. Strip trailing slashes from result (but keep lone /)
;   6. Output result
; ============================================================
do_dirname:
    push    rbp
    push    r13
    push    r12
    mov     rbp, rdi

    ; Get string length
    call    str_len
    mov     r13d, eax           ; length
    test    r13d, r13d
    jz      .dn_output_dot      ; empty string -> "."

    ; Step 1: Strip trailing slashes
    lea     ecx, [r13d - 1]
.dn_strip_trailing:
    cmp     ecx, 0
    jle     .dn_all_slashes_check
    cmp     byte [rbp + rcx], '/'
    jne     .dn_found_end
    dec     ecx
    jmp     .dn_strip_trailing

.dn_all_slashes_check:
    ; ecx == 0, check if it's also a slash
    cmp     byte [rbp], '/'
    jne     .dn_found_end
    ; Entire string is slashes -> result is "/"
    jmp     .dn_output_slash

.dn_found_end:
    ; ecx = index of last non-slash char
    ; Now find last slash before ecx (searching backwards)
    mov     r12d, ecx           ; save end position
    dec     ecx
.dn_find_last_slash:
    cmp     ecx, 0
    jl      .dn_output_dot      ; no slash found -> "."
    cmp     byte [rbp + rcx], '/'
    je      .dn_got_slash
    dec     ecx
    jmp     .dn_find_last_slash

.dn_got_slash:
    ; ecx = index of last slash
    ; Now strip trailing slashes from result (but keep at least one if at position 0)
    mov     r12d, ecx           ; end of dirname (exclusive, points at slash)
.dn_strip_result_trailing:
    cmp     r12d, 0
    jle     .dn_result_root_check
    cmp     byte [rbp + r12], '/'
    jne     .dn_output_result
    dec     r12d
    jmp     .dn_strip_result_trailing

.dn_result_root_check:
    ; r12d == 0
    cmp     byte [rbp], '/'
    jne     .dn_output_result
    ; Result is "/" (lone slash)
    jmp     .dn_output_slash

.dn_output_result:
    ; Output rbp[0..r12d] (inclusive)
    lea     r13d, [r12d + 1]    ; length
    mov     edi, STDOUT
    mov     rsi, rbp
    mov     edx, r13d
    call    do_write
    jmp     .dn_terminator

.dn_output_dot:
    mov     edi, STDOUT
    mov     rsi, str_dot
    mov     edx, 1
    call    do_write
    jmp     .dn_terminator

.dn_output_slash:
    mov     edi, STDOUT
    mov     rsi, str_slash
    mov     edx, 1
    call    do_write
    jmp     .dn_terminator

.dn_terminator:
    ; Write newline or NUL
    test    bl, 2
    jnz     .dn_write_nul
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write
    jmp     .dn_done

.dn_write_nul:
    mov     edi, STDOUT
    mov     rsi, str_nul
    mov     edx, 1
    call    do_write

.dn_done:
    pop     r12
    pop     r13
    pop     rbp
    ret

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
; Clobbers: r8, eax, edx
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

; str_prefix_match: compare first edx bytes of rdi with rsi
; Returns eax: 1=match, 0=no match. Clobbers: r8, eax
str_prefix_match:
    xor     r8d, r8d
.sp_loop:
    cmp     r8d, edx
    jge     .sp_match
    movzx   eax, byte [rdi + r8]
    cmp     al, byte [rsi + r8]
    jne     .sp_nomatch
    inc     r8d
    jmp     .sp_loop
.sp_match:
    mov     eax, 1
    ret
.sp_nomatch:
    xor     eax, eax
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: dirname [OPTION] NAME...", 10
    db "Output each NAME with its last non-slash component and trailing slashes", 10
    db "removed; if NAME contains no /'s, output '.' (meaning the current", 10
    db "directory).", 10, 10
    db "  -z, --zero     end each output line with NUL, not newline", 10
    db "      --help     display this help and exit", 10
    db "      --version  output version information and exit", 10, 10
    db "Examples:", 10
    db '  dirname /usr/bin/          -> "/usr"', 10
    db '  dirname dir1/str dir2/str  -> "dir1" followed by "dir2"', 10
    db '  dirname stdio.h            -> "."', 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/dirname>", 10
    db "or available locally via: info '(coreutils) dirname invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "dirname (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by David MacKenzie.", 10
str_version_len equ $ - str_version

str_prefix:      db "dirname: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_missing:     db "missing operand", 10
str_missing_len  equ $ - str_missing
str_sq_nl:       db "'", 10
str_try:         db "Try 'dirname --help' for more information.", 10
str_try_len      equ $ - str_try
; @@DATA_END@@

str_newline:     db 10
str_nul:         db 0
str_dot:         db "."
str_slash:       db "/"
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_zero_flag:   db "--zero", 0

file_size equ $ - $$
