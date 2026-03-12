; ============================================================
; fprintenv_unified.asm — GNU-compatible 'printenv' command
; Builds with: nasm -f bin fprintenv_unified.asm -o fprintenv
;
; printenv: Print all or part of the environment.
;
; Register allocation:
;   r14d = argc, r15 = argv, ebx = flags (bit 0 = -0/--null)
;   ecx  = arg index during option parsing
;   r12  = envp base pointer
;   r13  = current arg index / iteration counter
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
    xor     ebx, ebx            ; flags: bit 0 = -0/--null
    mov     ecx, 1              ; arg index (start after argv[0])

    ; Compute envp: skip past argv[] and its NULL terminator
    ; envp = rsp + 8 + 8*(argc+1)  (i.e., argv + (argc+1)*8)
    mov     eax, r14d
    inc     eax
    lea     r12, [r15 + rax*8]  ; r12 = envp

    ; Parse options
.parse_opts:
    cmp     ecx, r14d
    jge     .done_opts
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .done_opts
    cmp     byte [rdi + 1], 0
    je      .done_opts           ; bare "-" is not an option
    cmp     byte [rdi + 1], '-'
    je      .check_long

    ; Short options: -0 (can be combined, e.g., -00)
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, '0'
    je      .set_null
    ; Invalid short option — save char pointer
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
    mov     edi, 2
    jmp     do_exit

.set_null:
    or      bl, 1
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
    ; Check --null
    mov     rdi, r13
    mov     rsi, str_null_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_long_null
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
    mov     edi, 2
    jmp     do_exit

.pop_show_help:
    pop     rcx
    jmp     .show_help
.pop_show_version:
    pop     rcx
    jmp     .show_version
.pop_set_long_null:
    pop     rcx
    or      bl, 1
    jmp     .next_opt

.double_dash:
    inc     ecx
    jmp     .done_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

.done_opts:
    ; ecx = index of first var name arg (or == argc if none)
    cmp     ecx, r14d
    jge     .print_all_env

    ; --- Print specific variables ---
    ; r13d = current arg index, rbp = "any not found" flag
    mov     r13d, ecx
    xor     ebp, ebp            ; 0 = all found so far

.var_loop:
    cmp     r13d, r14d
    jge     .var_done
    mov     rdi, [r15 + r13*8]  ; var name to find
    ; Scan environment for this var
    xor     ecx, ecx            ; env index
.env_scan:
    mov     rsi, [r12 + rcx*8]  ; envp[i]
    test    rsi, rsi
    jz      .var_not_found
    ; Check if envp[i] starts with "NAME="
    push    rcx
    push    rdi
    call    .match_env_prefix
    pop     rdi
    pop     rcx
    test    rax, rax
    jnz     .var_found
    inc     ecx
    jmp     .env_scan

.var_not_found:
    mov     ebp, 1              ; mark as "some not found"
    inc     r13d
    jmp     .var_loop

.var_found:
    ; rax = pointer to value (past the '=')
    ; Write the value
    mov     rdi, rax
    push    rdi
    call    str_len
    pop     rdi
    mov     edx, eax            ; value length
    mov     rsi, rdi
    mov     edi, STDOUT
    test    edx, edx
    jz      .var_terminator
    call    do_write

.var_terminator:
    ; Write newline or NUL
    test    bl, 1
    jnz     .var_write_nul
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write
    jmp     .var_next

.var_write_nul:
    mov     edi, STDOUT
    mov     rsi, str_nul
    mov     edx, 1
    call    do_write

.var_next:
    inc     r13d
    jmp     .var_loop

.var_done:
    mov     edi, ebp            ; 0 if all found, 1 if any missing
    jmp     do_exit

    ; --- Print all environment ---
.print_all_env:
    xor     r13d, r13d          ; env index
.all_loop:
    mov     rdi, [r12 + r13*8]
    test    rdi, rdi
    jz      .all_done
    ; Write the full KEY=VALUE string
    push    rdi
    call    str_len
    pop     rdi
    mov     edx, eax
    mov     rsi, rdi
    mov     edi, STDOUT
    test    edx, edx
    jz      .all_terminator
    call    do_write

.all_terminator:
    test    bl, 1
    jnz     .all_write_nul
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write
    jmp     .all_next

.all_write_nul:
    mov     edi, STDOUT
    mov     rsi, str_nul
    mov     edx, 1
    call    do_write

.all_next:
    inc     r13d
    jmp     .all_loop

.all_done:
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

; ============================================================
; match_env_prefix: check if env string starts with "NAME="
; Input: rdi = name (NUL-terminated), rsi = env entry
; Returns: rax = pointer past '=' if match, 0 if no match
; Clobbers: r8, r9, rax
; ============================================================
.match_env_prefix:
    xor     r8d, r8d
.mep_loop:
    movzx   eax, byte [rdi + r8]
    test    al, al
    jz      .mep_check_eq       ; end of name, check for '='
    movzx   r9d, byte [rsi + r8]
    cmp     al, r9b
    jne     .mep_no
    inc     r8d
    jmp     .mep_loop
.mep_check_eq:
    cmp     byte [rsi + r8], '='
    jne     .mep_no
    lea     rax, [rsi + r8 + 1] ; pointer past '='
    ret
.mep_no:
    xor     eax, eax
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

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: printenv [OPTION]... [VARIABLE]...", 10
    db "Print the values of the specified environment VARIABLE(s).", 10
    db "If no VARIABLE is specified, print name and value pairs for them all.", 10, 10
    db "  -0, --null     end each output line with NUL, not newline", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "NOTE: your shell may have its own version of printenv, which usually supersedes", 10
    db "the version described here.  Please refer to your shell's documentation", 10
    db "for details about the options it supports.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/printenv>", 10
    db "or available locally via: info '(coreutils) printenv invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "printenv (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by David MacKenzie and Richard Mlynarik.", 10
str_version_len equ $ - str_version

str_prefix:      db "printenv: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_sq_nl:       db "'", 10
str_try:         db "Try 'printenv --help' for more information.", 10
str_try_len      equ $ - str_try
; @@DATA_END@@

str_newline:     db 10
str_nul:         db 0
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_null_flag:   db "--null", 0

file_size equ $ - $$
