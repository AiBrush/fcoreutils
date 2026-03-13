; ============================================================
; fchcon_unified.asm — GNU-compatible 'chcon' command
; Builds with: nasm -f bin fchcon_unified.asm -o fchcon
;
; chcon: change file SELinux security context
;
; Usage: chcon [OPTION]... CONTEXT FILE...
;        chcon [OPTION]... [-u USER] [-r ROLE] [-t TYPE] [-l RANGE] FILE...
;        chcon [OPTION]... --reference=RFILE FILE...
;
; On non-SELinux systems: prints "Operation not supported"
; Syscall: lsetxattr(189) with "security.selinux"
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE       1
%define SYS_EXIT       60
%define SYS_LSETXATTR 189
%define SYS_LGETXATTR 191
%define SYS_RT_SIGPROCMASK 14

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13

; === ELF Header ===
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
    dw ehdr_size
    dw phdr_size
    dw 2
    dw 64, 0, 0
ehdr_size equ $ - ehdr

phdr:
    dd 1, 7
    dq 0, $$, $$
    dq file_size, mem_size
    dq 0x200000
phdr_size equ $ - phdr

    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 16

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

    mov     r14d, [rsp]
    lea     r15, [rsp + 8]

    ; Flags
    xor     r12d, r12d          ; verbose = 0
    xor     r13d, r13d          ; recursive = 0 (not implemented in asm)
    mov     ecx, 1              ; arg index
    xor     ebx, ebx            ; context_arg_idx = 0

    ; Parse options
.parse_opts:
    cmp     ecx, r14d
    jge     .check_args
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .end_opts
    cmp     byte [rdi + 1], 0
    je      .end_opts
    cmp     byte [rdi + 1], '-'
    je      .check_long

    ; Short options
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'v'
    je      .set_verbose
    cmp     al, 'R'
    je      .set_recursive
    cmp     al, 'h'
    je      .set_deref
    cmp     al, 'H'
    je      .set_deref
    cmp     al, 'L'
    je      .set_deref
    cmp     al, 'P'
    je      .set_deref
    ; -u USER, -r ROLE, -t TYPE, -l RANGE: skip next arg
    cmp     al, 'u'
    je      .skip_short_val
    cmp     al, 'r'
    je      .skip_short_val
    cmp     al, 't'
    je      .skip_short_val
    cmp     al, 'l'
    je      .skip_short_val
    jmp     .invalid_short

.set_verbose:
    mov     r12d, 1
    inc     rdi
    jmp     .short_loop
.set_recursive:
    mov     r13d, 1
    inc     rdi
    jmp     .short_loop
.set_deref:
    inc     rdi
    jmp     .short_loop
.skip_short_val:
    ; Check if value is attached or next arg
    cmp     byte [rdi + 1], 0
    jne     .val_attached
    ; Value is next arg — skip it
    inc     ecx
    jmp     .next_opt
.val_attached:
    ; Rest of arg is the value
    jmp     .next_opt

.check_long:
    push    rcx
    ; --help
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .show_help
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .show_version
    ; --reference=
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_reference_prefix
    call    starts_with
    test    eax, eax
    jnz     .pop_next
    pop     rcx
    ; Check for -- end of options
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi + 2], 0
    je      .end_opts_inc
    jmp     .invalid_long

.pop_next:
    pop     rcx
    jmp     .next_opt

.invalid_short:
    mov     r8b, [rdi]
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    write_err
    mov     [char_buf], r8b
    mov     rsi, char_buf
    mov     edx, 1
    call    write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    write_err
    mov     edi, 1
    jmp     do_exit

.invalid_long:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_unrec
    mov     edx, str_unrec_len
    call    write_err
    mov     rdi, [r15 + rcx*8]
    call    str_len
    mov     edx, eax
    mov     rsi, [r15 + rcx*8]
    call    write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    write_err
    mov     edi, 1
    jmp     do_exit

.next_opt:
    inc     ecx
    jmp     .parse_opts

.end_opts_inc:
    inc     ecx
.end_opts:
    ; ecx = first non-option arg (the CONTEXT)
    ; Need at least CONTEXT + 1 FILE
    mov     ebx, ecx            ; context_arg_idx
    inc     ecx                 ; ecx = first file arg

.check_args:
    cmp     ecx, r14d
    jge     .missing_operand

    ; For each FILE argument, try lsetxattr
    mov     r8d, ecx            ; file arg index
    xor     r13d, r13d          ; error_count

.file_loop:
    cmp     r8d, r14d
    jge     .done_files

    ; lsetxattr(path, "security.selinux", context, context_len, 0)
    mov     rdi, [r15 + r8*8]          ; path
    mov     rsi, str_selinux_attr      ; name
    mov     rdx, [r15 + rbx*8]        ; context value
    ; Calculate context length
    push    rdi
    push    r8
    mov     rdi, rdx
    call    str_len
    mov     r10d, eax                  ; context_len
    pop     r8
    pop     rdi

    mov     rdi, [r15 + r8*8]
    mov     rsi, str_selinux_attr
    mov     rdx, [r15 + rbx*8]
    mov     r10d, r10d                 ; size (already in r10d)
    xor     r9d, r9d                   ; flags = 0
    ; Shuffle: syscall args rdi, rsi, rdx, r10, r8(kernel), r9(kernel)
    ; lsetxattr(path, name, value, size, flags)
    ; rdi=path, rsi=name, rdx=value, r10=size, r8=flags
    push    r8
    mov     r8d, 0                     ; flags = 0
    mov     eax, SYS_LSETXATTR
    syscall
    pop     r8
    test    rax, rax
    js      .file_error

    ; Verbose output
    test    r12d, r12d
    jz      .file_next
    ; Print: "changing security context of 'FILE'"
    push    r8
    mov     edi, STDOUT
    mov     rsi, str_changing
    mov     edx, str_changing_len
    call    do_write
    mov     rdi, [r15 + r8*8]
    call    str_len
    mov     edx, eax
    mov     rsi, [r15 + r8*8]
    mov     edi, STDOUT
    call    do_write
    mov     edi, STDOUT
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write
    pop     r8
    jmp     .file_next

.file_error:
    inc     r13d
    ; Print error: "chcon: failed to change context of 'FILE' to 'CTX': Op not supported"
    push    r8
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_failed_ctx
    mov     edx, str_failed_ctx_len
    call    write_err
    pop     r8
    push    r8
    mov     rdi, [r15 + r8*8]
    call    str_len
    mov     edx, eax
    mov     rsi, [r15 + r8*8]
    call    write_err
    mov     rsi, str_to_ctx
    mov     edx, str_to_ctx_len
    call    write_err
    mov     rdi, [r15 + rbx*8]
    call    str_len
    mov     edx, eax
    mov     rsi, [r15 + rbx*8]
    call    write_err
    mov     rsi, str_op_not_sup
    mov     edx, str_op_not_sup_len
    call    write_err
    pop     r8

.file_next:
    inc     r8d
    jmp     .file_loop

.done_files:
    test    r13d, r13d
    jnz     .exit_fail
    xor     edi, edi
    jmp     do_exit
.exit_fail:
    mov     edi, 1
    jmp     do_exit

.missing_operand:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_missing_op
    mov     edx, str_missing_op_len
    call    write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    write_err
    mov     edi, 1
    jmp     do_exit

.show_help:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.show_version:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
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

write_err:
    mov     edi, STDERR
    jmp     do_write

do_exit:
    mov     eax, SYS_EXIT
    syscall

str_len:
    xor     eax, eax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     eax
    jmp     .loop
.done:
    ret

str_eq:
    xor     r8d, r8d
.loop:
    movzx   eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    cmp     al, dl
    jne     .ne
    test    al, al
    jz      .eq
    inc     r8d
    jmp     .loop
.eq:
    mov     eax, 1
    ret
.ne:
    xor     eax, eax
    ret

starts_with:
    xor     r8d, r8d
.loop:
    movzx   eax, byte [rsi + r8]
    test    al, al
    jz      .match
    cmp     al, byte [rdi + r8]
    jne     .no
    inc     r8d
    jmp     .loop
.match:
    mov     eax, 1
    ret
.no:
    xor     eax, eax
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: chcon [OPTION]... CONTEXT FILE...", 10
    db "  or:  chcon [OPTION]... [-u USER] [-r ROLE] [-l RANGE] [-t TYPE] FILE...", 10
    db "  or:  chcon [OPTION]... --reference=RFILE FILE...", 10
    db "Change the SELinux security context of each FILE to CONTEXT.", 10
    db "With --reference, change the security context of each FILE to that of RFILE.", 10, 10
    db "      --dereference      affect the referent of each symbolic link (this is", 10
    db "                         the default), rather than the symbolic link itself", 10
    db "  -h, --no-dereference   affect symbolic links instead of any referenced file", 10
    db "  -u, --user=USER        set user USER in the target security context", 10
    db "  -r, --role=ROLE        set role ROLE in the target security context", 10
    db "  -t, --type=TYPE        set type TYPE in the target security context", 10
    db "  -l, --range=RANGE      set range RANGE in the target security context", 10
    db "      --no-preserve-root  do not treat '/' specially (the default)", 10
    db "      --preserve-root    fail to operate recursively on '/'", 10
    db "      --reference=RFILE  use RFILE's security context rather than specifying", 10
    db "                         a CONTEXT value", 10
    db "  -R, --recursive        operate on files and directories recursively", 10
    db "  -v, --verbose          output a diagnostic for every file processed", 10, 10
    db "The following options modify how a hierarchy is traversed when the -R", 10
    db "option is also specified.  If more than one is specified, only the final", 10
    db "one takes effect.", 10, 10
    db "  -H                     if a command line argument is a symbolic link", 10
    db "                         to a directory, traverse it", 10
    db "  -L                     traverse every symbolic link to a directory", 10
    db "                         encountered", 10
    db "  -P                     do not traverse any symbolic links (default)", 10, 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/chcon>", 10
    db "or available locally via: info '(coreutils) chcon invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "chcon (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Russell Coker and Jim Meyering.", 10
str_version_len equ $ - str_version
; @@DATA_END@@

str_prefix:             db "chcon: "
str_prefix_len          equ $ - str_prefix
str_try:                db "Try 'chcon --help' for more information.", 10
str_try_len             equ $ - str_try
str_missing_op:         db "missing operand", 10
str_missing_op_len      equ $ - str_missing_op
str_unrec:              db "unrecognized option '"
str_unrec_len           equ $ - str_unrec
str_invalid:            db "invalid option -- '"
str_invalid_len         equ $ - str_invalid
str_sq_nl:              db "'", 10
str_failed_ctx:         db "failed to change context of '"
str_failed_ctx_len      equ $ - str_failed_ctx
str_to_ctx:             db "' to '"
str_to_ctx_len          equ $ - str_to_ctx
str_op_not_sup:         db "': Operation not supported", 10
str_op_not_sup_len      equ $ - str_op_not_sup
str_changing:           db "changing security context of '"
str_changing_len        equ $ - str_changing
str_selinux_attr:       db "security.selinux", 0

str_help_flag:          db "--help", 0
str_version_flag:       db "--version", 0
str_reference_prefix:   db "--reference=", 0

file_size equ $ - $$

char_buf: db 0, 0

mem_size equ $ - $$
