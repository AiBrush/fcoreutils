; ============================================================
; fbasename_unified.asm — GNU-compatible 'basename' command
; Builds with: nasm -f bin fbasename_unified.asm -o fbasename
;
; basename: Strip directory and suffix from filenames.
;
; Register allocation:
;   r14d = argc, r15 = argv, ebx = flags, r12 = suffix ptr
;   ecx  = arg index during option parsing
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
    xor     ebx, ebx            ; flags: bit 0 = -a/--multiple, bit 1 = -z/--zero
    xor     r12, r12            ; suffix pointer (0 = none)
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

    ; Short options: -a, -s, -z (can be combined: -az)
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'a'
    je      .set_multi
    cmp     al, 'z'
    je      .set_zero
    cmp     al, 's'
    je      .set_suffix_short
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
    mov     edi, 1
    jmp     do_exit

.set_multi:
    or      bl, 1
    inc     rdi
    jmp     .short_loop

.set_zero:
    or      bl, 2
    inc     rdi
    jmp     .short_loop

.set_suffix_short:
    or      bl, 1               ; -s implies -a
    inc     rdi
    cmp     byte [rdi], 0
    jne     .suffix_inline
    ; Suffix is the next argument
    inc     ecx
    cmp     ecx, r14d
    jge     .err_suffix_missing
    mov     r12, [r15 + rcx*8]
    jmp     .next_opt

.suffix_inline:
    mov     r12, rdi
    jmp     .next_opt

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
    ; Save arg pointer in r13 (str_eq clobbers ecx/edx, but we save ecx)
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
    ; Check --multiple
    mov     rdi, r13
    mov     rsi, str_multiple_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_long_multi
    ; Check --zero
    mov     rdi, r13
    mov     rsi, str_zero_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_long_zero
    ; Check --suffix=
    mov     rdi, r13
    mov     rsi, str_suffix_prefix
    mov     edx, 9               ; length of "--suffix="
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_long_suffix
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
    mov     edi, 1
    jmp     do_exit

.pop_show_help:
    pop     rcx
    jmp     .show_help
.pop_show_version:
    pop     rcx
    jmp     .show_version
.pop_set_long_multi:
    pop     rcx
    or      bl, 1
    jmp     .next_opt
.pop_set_long_zero:
    pop     rcx
    or      bl, 2
    jmp     .next_opt
.pop_set_long_suffix:
    pop     rcx
    or      bl, 1               ; --suffix implies -a
    lea     r12, [r13 + 9]      ; skip "--suffix="
    jmp     .next_opt

.double_dash:
    inc     ecx
    jmp     .done_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

.err_suffix_missing:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_opt_req_arg
    mov     edx, str_opt_req_arg_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.done_opts:
    ; ecx = index of first filename arg
    cmp     ecx, r14d
    jge     .err_missing_operand

    ; If -a flag NOT set and we have exactly 2 remaining args,
    ; second is treated as suffix (traditional basename NAME SUFFIX form)
    test    bl, 1
    jnz     .process_files
    mov     eax, r14d
    sub     eax, ecx
    cmp     eax, 2
    je      .traditional_suffix
    cmp     eax, 1
    je      .process_files
    ; More than 2 args without -a → extra operand error
    mov     eax, ecx
    add     eax, 2
    mov     r13, [r15 + rax*8]  ; save the extra operand pointer
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_extra
    mov     edx, str_extra_len
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
    mov     edi, 1
    jmp     do_exit

.traditional_suffix:
    ; Set suffix from argv[ecx+1]
    mov     eax, ecx
    inc     eax
    mov     r12, [r15 + rax*8]
    ; Process just one file
    mov     rdi, [r15 + rcx*8]
    call    do_basename
    jmp     .exit_ok

.process_files:
    ; Process remaining args as filenames
    mov     r13d, ecx           ; current file index
.file_loop:
    cmp     r13d, r14d
    jge     .exit_ok
    mov     rdi, [r15 + r13*8]
    call    do_basename
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
; do_basename: process one filename
; Input: rdi = filename string pointer
; Uses: r12 = suffix (0 if none), bl flags (bit 1 = -z)
; ============================================================
do_basename:
    push    rbp
    push    r13
    push    r12
    mov     rbp, rdi

    ; Get string length
    call    str_len
    mov     r13d, eax           ; length
    test    r13d, r13d
    jz      .bn_output          ; empty string → output empty

    ; Strip trailing slashes (but if entire string is slashes, keep one)
    lea     ecx, [r13d - 1]
.bn_strip_trailing:
    cmp     ecx, 0
    jle     .bn_all_slashes_check
    cmp     byte [rbp + rcx], '/'
    jne     .bn_found_end
    dec     ecx
    jmp     .bn_strip_trailing

.bn_all_slashes_check:
    ; ecx == 0, check if it's also a slash
    cmp     byte [rbp], '/'
    jne     .bn_found_end
    ; Entire string is slashes → result is "/"
    mov     r13d, 1
    jmp     .bn_output

.bn_found_end:
    ; ecx = index of last non-slash char
    lea     r13d, [ecx + 1]     ; new length (up to last non-slash + 1)

    ; Find the last slash before r13d
    mov     ecx, r13d
    dec     ecx
.bn_find_last_slash:
    cmp     ecx, 0
    jl      .bn_no_slash
    cmp     byte [rbp + rcx], '/'
    je      .bn_got_slash
    dec     ecx
    jmp     .bn_find_last_slash

.bn_no_slash:
    ; No slash found, the whole string (up to r13d) is the basename
    jmp     .bn_check_suffix

.bn_got_slash:
    ; Skip past the slash
    inc     ecx
    add     rbp, rcx
    sub     r13d, ecx

.bn_check_suffix:
    ; Check if suffix matches and should be removed
    test    r12, r12
    jz      .bn_output
    ; Get suffix length
    mov     rdi, r12
    push    r13
    call    str_len
    pop     r13
    mov     edx, eax            ; suffix length
    test    edx, edx
    jz      .bn_output          ; empty suffix → no removal
    cmp     edx, r13d
    jge     .bn_output          ; suffix >= basename → don't remove (must leave at least 1 char)
    ; Compare suffix at end of basename
    mov     ecx, r13d
    sub     ecx, edx            ; offset where suffix would start
    lea     r8, [rbp + rcx]
    xor     eax, eax
.bn_suffix_cmp:
    cmp     eax, edx
    jge     .bn_suffix_match
    movzx   esi, byte [r8 + rax]
    cmp     sil, byte [r12 + rax]
    jne     .bn_output          ; no match
    inc     eax
    jmp     .bn_suffix_cmp

.bn_suffix_match:
    sub     r13d, edx           ; remove suffix

.bn_output:
    ; Write the basename
    mov     edi, STDOUT
    mov     rsi, rbp
    mov     edx, r13d
    test    edx, edx
    jz      .bn_terminator
    call    do_write

.bn_terminator:
    ; Write newline or NUL
    test    bl, 2
    jnz     .bn_write_nul
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write
    jmp     .bn_done

.bn_write_nul:
    mov     edi, STDOUT
    mov     rsi, str_nul
    mov     edx, 1
    call    do_write

.bn_done:
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
    db "Usage: basename NAME [SUFFIX]", 10
    db "  or:  basename OPTION... NAME...", 10
    db "Print NAME with any leading directory components removed.", 10
    db "If specified, also remove a trailing SUFFIX.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -a, --multiple       support multiple arguments and treat each as a NAME", 10
    db "  -s, --suffix=SUFFIX  remove a trailing SUFFIX; implies -a", 10
    db "  -z, --zero           end each output line with NUL, not newline", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "Examples:", 10
    db '  basename /usr/bin/sort          -> "sort"', 10
    db '  basename include/stdio.h .h     -> "stdio"', 10
    db '  basename -s .h include/stdio.h  -> "stdio"', 10
    db '  basename -a any/str1 any/str2   -> "str1" followed by "str2"', 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/basename>", 10
    db "or available locally via: info '(coreutils) basename invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "basename (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by David MacKenzie.", 10
str_version_len equ $ - str_version

str_prefix:      db "basename: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_extra:       db "extra operand '"
str_extra_len    equ $ - str_extra
str_missing:     db "missing operand", 10
str_missing_len  equ $ - str_missing
str_sq_nl:       db "'", 10
str_try:         db "Try 'basename --help' for more information.", 10
str_try_len      equ $ - str_try
str_opt_req_arg: db "option requires an argument -- 's'", 10
str_opt_req_arg_len equ $ - str_opt_req_arg
; @@DATA_END@@

str_newline:     db 10
str_nul:         db 0
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_multiple_flag: db "--multiple", 0
str_zero_flag:   db "--zero", 0
str_suffix_prefix: db "--suffix=", 0

file_size equ $ - $$
