; ============================================================
; fpathchk_unified.asm — GNU-compatible 'pathchk' command
; Builds with: nasm -f bin fpathchk_unified.asm -o fpathchk
;
; pathchk: Check whether file names are valid or portable.
;
; Register allocation:
;   r14d = argc, r15 = argv, ebx = flags, ecx = arg index
;   r13  = path index during path loop
;   Flags: bit 0 = -p (POSIX portable), bit 1 = -P (extra)
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

%define NAME_MAX_LOCAL  255
%define PATH_MAX_LOCAL  4096
%define NAME_MAX_POSIX  14

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

    ; Initialize
    xor     ebx, ebx            ; flags: bit 0 = -p, bit 1 = -P
    mov     ecx, 1              ; arg index
    xor     r12d, r12d          ; exit code (0 = success)

    ; Parse options
.parse_opts:
    cmp     ecx, r14d
    jge     .err_missing_operand
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .done_opts
    cmp     byte [rdi + 1], 0
    je      .done_opts           ; bare "-" is a path, not an option
    cmp     byte [rdi + 1], '-'
    je      .check_long

    ; Short options: -p, -P (can be combined)
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'p'
    je      .set_posix
    cmp     al, 'P'
    je      .set_extra
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

.set_posix:
    or      bl, 1
    inc     rdi
    jmp     .short_loop

.set_extra:
    or      bl, 2
    inc     rdi
    jmp     .short_loop

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
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
    ; Check --portability
    mov     rdi, r13
    mov     rsi, str_portability_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_portability
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
.pop_set_portability:
    pop     rcx
    or      bl, 3               ; set both -p (bit 0) and -P (bit 1)
    jmp     .next_opt

.double_dash:
    inc     ecx
    jmp     .done_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

.done_opts:
    ; ecx = index of first path argument
    cmp     ecx, r14d
    jge     .err_missing_operand

    ; Process paths
    mov     r13d, ecx
.path_loop:
    cmp     r13d, r14d
    jge     .exit_done
    mov     rdi, [r15 + r13*8]
    call    check_path
    inc     r13d
    jmp     .path_loop

.exit_done:
    mov     edi, r12d
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
; check_path: validate one path
; Input: rdi = path string, ebx = flags, r12d = exit code (updated)
; ============================================================
check_path:
    push    rbp
    push    r13
    push    r14
    push    rbx
    mov     rbp, rdi            ; rbp = path pointer

    ; Get path length
    call    str_len
    mov     r13d, eax           ; r13d = path length

    ; Check for empty path (always, not just -P)
    test    r13d, r13d
    jz      .cp_empty_path

.cp_not_empty:
    ; Check total path length
    test    bl, 1               ; -p flag?
    jnz     .cp_check_posix_pathlen
    cmp     r13d, PATH_MAX_LOCAL
    jg      .cp_path_too_long
    jmp     .cp_walk_components

.cp_check_posix_pathlen:
    cmp     r13d, PATH_MAX_LOCAL
    jg      .cp_path_too_long

.cp_walk_components:
    ; Walk path components separated by /
    ; r14d = current position in path
    xor     r14d, r14d          ; position = 0

    ; Skip leading slashes (they are not components)
.cp_skip_leading_slash:
    cmp     r14d, r13d
    jge     .cp_done
    cmp     byte [rbp + r14], '/'
    jne     .cp_component_start
    inc     r14d
    jmp     .cp_skip_leading_slash

.cp_component_start:
    ; r14d points to start of a component (or end of path)
    cmp     r14d, r13d
    jge     .cp_done

    ; Find end of this component (next / or end)
    mov     ecx, r14d           ; ecx = component start
.cp_find_end:
    cmp     ecx, r13d
    jge     .cp_got_component
    cmp     byte [rbp + rcx], '/'
    je      .cp_got_component
    inc     ecx
    jmp     .cp_find_end

.cp_got_component:
    ; Component is from r14d to ecx (exclusive), length = ecx - r14d
    mov     edx, ecx
    sub     edx, r14d           ; edx = component length
    push    rcx                 ; save end position

    ; -P: check for empty component (consecutive slashes)
    test    bl, 2
    jz      .cp_check_leading_hyphen
    test    edx, edx
    jz      .cp_empty_component_pop

.cp_check_leading_hyphen:
    ; -P: check for leading hyphen
    test    bl, 2
    jz      .cp_check_comp_len
    cmp     byte [rbp + r14], '-'
    je      .cp_leading_hyphen_pop

.cp_check_comp_len:
    ; Check component length
    test    bl, 1               ; -p flag?
    jnz     .cp_posix_comp_len
    cmp     edx, NAME_MAX_LOCAL
    jg      .cp_comp_too_long_pop
    jmp     .cp_check_portable_chars

.cp_posix_comp_len:
    cmp     edx, NAME_MAX_POSIX
    jg      .cp_comp_too_long_pop

.cp_check_portable_chars:
    ; -p: check all chars in component are portable
    test    bl, 1
    jz      .cp_next_component

    ; Check each char: A-Za-z0-9._-
    push    rdx                 ; save component length
    mov     eax, r14d           ; eax = current char position
.cp_char_loop:
    mov     edx, [rsp]          ; reload component length
    lea     esi, [r14d]
    add     esi, edx
    cmp     eax, esi
    jge     .cp_chars_ok
    movzx   edi, byte [rbp + rax]
    ; Check if char is in portable set: A-Za-z0-9._-
    cmp     dil, '0'
    jb      .cp_check_dot
    cmp     dil, '9'
    jbe     .cp_char_ok
    cmp     dil, 'A'
    jb      .cp_nonportable_char
    cmp     dil, 'Z'
    jbe     .cp_char_ok
    cmp     dil, '_'
    je      .cp_char_ok
    cmp     dil, 'a'
    jb      .cp_nonportable_char
    cmp     dil, 'z'
    jbe     .cp_char_ok
    jmp     .cp_nonportable_char
.cp_check_dot:
    cmp     dil, '.'
    je      .cp_char_ok
    cmp     dil, '-'
    je      .cp_char_ok
    jmp     .cp_nonportable_char

.cp_char_ok:
    inc     eax
    jmp     .cp_char_loop

.cp_chars_ok:
    pop     rdx
    jmp     .cp_next_component

.cp_nonportable_char:
    ; Non-portable character found - save position in r14 (reuse ok, done with components)
    ; eax = position of bad char in path
    ; First, copy the bad char byte to a safe place on the stack
    pop     rdx                 ; discard saved component length
    pop     rcx                 ; discard saved end position
    ; Save the bad char offset
    push    rax
    ; Print error: "pathchk: non-portable character 'X' in file name 'path'"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_nonportable_char
    mov     edx, str_nonportable_char_len
    call    do_write_err
    ; Write the character - restore saved offset
    pop     rax
    lea     rsi, [rbp + rax]
    mov     edx, 1
    call    do_write_err
    mov     rsi, str_in_filename
    mov     edx, str_in_filename_len
    call    do_write_err
    mov     rdi, rbp
    call    str_len
    mov     edx, eax
    mov     rsi, rbp
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     r12d, 1
    jmp     .cp_done

.cp_next_component:
    pop     rcx                 ; restore end position
    ; Skip past slashes after component
.cp_skip_slashes:
    cmp     ecx, r13d
    jge     .cp_done
    cmp     byte [rbp + rcx], '/'
    jne     .cp_set_next
    ; -P: check for empty component (consecutive slashes in middle)
    ; Actually consecutive slashes don't create empty components for -P,
    ; GNU pathchk treats // as one separator. Skip.
    inc     ecx
    jmp     .cp_skip_slashes

.cp_set_next:
    mov     r14d, ecx
    jmp     .cp_component_start

.cp_done:
    pop     rbx
    pop     r14
    pop     r13
    pop     rbp
    ret

; --- Error paths ---
.cp_empty_path:
    ; "pathchk: empty file name"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_empty_filename
    mov     edx, str_empty_filename_len
    call    do_write_err
    mov     r12d, 1
    jmp     .cp_done

.cp_path_too_long:
    ; "pathchk: limit X exceeded by length Y of file name 'path'"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_path_too_long
    mov     edx, str_path_too_long_len
    call    do_write_err
    mov     rdi, rbp
    call    str_len
    mov     edx, eax
    mov     rsi, rbp
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     r12d, 1
    jmp     .cp_done

.cp_empty_component_pop:
    pop     rcx
    ; "pathchk: empty file name"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_empty_component
    mov     edx, str_empty_component_len
    call    do_write_err
    mov     r12d, 1
    jmp     .cp_done

.cp_leading_hyphen_pop:
    pop     rcx
    ; "pathchk: leading '-' in a component of file name 'path'"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_leading_hyphen
    mov     edx, str_leading_hyphen_len
    call    do_write_err
    mov     rdi, rbp
    call    str_len
    mov     edx, eax
    mov     rsi, rbp
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     r12d, 1
    jmp     .cp_done

.cp_comp_too_long_pop:
    pop     rcx
    ; "pathchk: limit exceeded by length of file name component 'path'"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_comp_too_long
    mov     edx, str_comp_too_long_len
    call    do_write_err
    mov     rdi, rbp
    call    str_len
    mov     edx, eax
    mov     rsi, rbp
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     r12d, 1
    jmp     .cp_done

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
    db "Usage: pathchk [OPTION]... NAME...", 10
    db "Diagnose invalid or unportable file names.", 10, 10
    db "  -p                  check for most POSIX systems", 10
    db "  -P                  check for empty names and leading '-'", 10
    db "      --portability   check for all POSIX systems (equivalent to -p -P)", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/pathchk>", 10
    db "or available locally via: info '(coreutils) pathchk invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "pathchk (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Paul Eggert, David MacKenzie, and Jim Meyering.", 10
str_version_len equ $ - str_version

str_prefix:      db "pathchk: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_missing:     db "missing operand", 10
str_missing_len  equ $ - str_missing
str_sq_nl:       db "'", 10
str_sq:          db "'"
str_try:         db "Try 'pathchk --help' for more information.", 10
str_try_len      equ $ - str_try
str_empty_filename:     db "empty file name", 10
str_empty_filename_len  equ $ - str_empty_filename
str_path_too_long:      db "limit 4096 exceeded by length of file name '"
str_path_too_long_len   equ $ - str_path_too_long
str_comp_too_long:      db "limit exceeded by length of file name component '"
str_comp_too_long_len   equ $ - str_comp_too_long
str_leading_hyphen:     db "leading '-' in a component of file name '"
str_leading_hyphen_len  equ $ - str_leading_hyphen
str_empty_component:    db "empty file name", 10
str_empty_component_len equ $ - str_empty_component
str_nonportable_char:       db "non-portable character '"
str_nonportable_char_len    equ $ - str_nonportable_char
str_in_filename:        db "' in file name '"
str_in_filename_len     equ $ - str_in_filename
; @@DATA_END@@

str_newline:     db 10
str_nul:         db 0
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_portability_flag: db "--portability", 0

file_size equ $ - $$
