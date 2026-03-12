; ============================================================
; flink_unified.asm — GNU-compatible 'link' command
; Builds with: nasm -f bin flink_unified.asm -o flink
;
; link: Call the link function to create a hard link.
;
; Register allocation:
;   r14d = argc, r15 = argv
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE       1
%define SYS_LINK        86
%define SYS_EXIT       60
%define SYS_RT_SIGPROCMASK 14

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13

; errno values
%define EPERM           1
%define ENOENT          2
%define EACCES         13
%define EEXIST         17
%define ENOTDIR        20
%define EISDIR         21
%define EXDEV          18
%define EMLINK         31
%define ELOOP          40
%define ENAMETOOLONG   36
%define ENOSPC         28
%define EROFS          30
%define EIO             5
%define ENOMEM         12
%define EFAULT         14

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

    ; Check for --help/--version (only when argc == 2)
    cmp     r14d, 2
    jne     .check_argc
    mov     rdi, [r15 + 8]      ; argv[1]
    ; Check --help
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .show_help
    ; Check --version
    mov     rdi, [r15 + 8]
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .show_version

.check_argc:
    ; argc < 2: missing operand
    cmp     r14d, 2
    jl      .err_missing_operand
    ; argc == 2: missing operand after 'file1'
    cmp     r14d, 2
    je      .err_missing_operand_after
    ; argc > 3: extra operand
    cmp     r14d, 3
    jg      .err_extra_operand
    ; argc == 3: do the link

    ; Call link(argv[1], argv[2])
    mov     rdi, [r15 + 8]      ; oldpath = argv[1]
    mov     rsi, [r15 + 16]     ; newpath = argv[2]
    mov     eax, SYS_LINK
    syscall

    ; Check result
    test    rax, rax
    js      .link_error

    ; Success
    xor     edi, edi
    jmp     do_exit

.link_error:
    ; rax contains negative errno
    neg     rax                 ; now rax = positive errno
    mov     r12, rax            ; save errno

    ; Print: "link: cannot create link '"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err

    mov     rsi, str_cannot_create
    mov     edx, str_cannot_create_len
    call    do_write_err

    ; Print dest (argv[2])
    mov     rdi, [r15 + 16]
    call    str_len
    mov     edx, eax
    mov     rsi, [r15 + 16]
    call    do_write_err

    ; Print "' to '"
    mov     rsi, str_to
    mov     edx, str_to_len
    call    do_write_err

    ; Print source (argv[1])
    mov     rdi, [r15 + 8]
    call    str_len
    mov     edx, eax
    mov     rsi, [r15 + 8]
    call    do_write_err

    ; Print "': "
    mov     rsi, str_colon_space
    mov     edx, str_colon_space_len
    call    do_write_err

    ; Map errno to error message
    mov     rdi, r12
    call    errno_to_msg        ; returns rsi=msg, edx=len

    call    do_write_err

    ; Print newline
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write_err

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

.err_missing_operand_after:
    ; "link: missing operand after 'FILE'\n"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err

    mov     rsi, str_missing_after
    mov     edx, str_missing_after_len
    call    do_write_err

    ; Print the filename (argv[1])
    mov     rdi, [r15 + 8]
    call    str_len
    mov     edx, eax
    mov     rsi, [r15 + 8]
    call    do_write_err

    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err

    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.err_extra_operand:
    ; "link: extra operand 'FILE3'\n"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err

    mov     rsi, str_extra
    mov     edx, str_extra_len
    call    do_write_err

    ; Print the extra operand (argv[3])
    mov     rdi, [r15 + 24]
    call    str_len
    mov     edx, eax
    mov     rsi, [r15 + 24]
    call    do_write_err

    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err

    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; ============================================================
; errno_to_msg: map errno to error string
; Input: rdi = errno value
; Output: rsi = pointer to message, edx = length
; ============================================================
errno_to_msg:
    cmp     edi, EPERM
    je      .e_eperm
    cmp     edi, ENOENT
    je      .e_enoent
    cmp     edi, EIO
    je      .e_eio
    cmp     edi, EACCES
    je      .e_eacces
    cmp     edi, EEXIST
    je      .e_eexist
    cmp     edi, EXDEV
    je      .e_exdev
    cmp     edi, ENOTDIR
    je      .e_enotdir
    cmp     edi, EISDIR
    je      .e_eisdir
    cmp     edi, ENOMEM
    je      .e_enomem
    cmp     edi, EROFS
    je      .e_erofs
    cmp     edi, EMLINK
    je      .e_emlink
    cmp     edi, ENOSPC
    je      .e_enospc
    cmp     edi, ELOOP
    je      .e_eloop
    cmp     edi, ENAMETOOLONG
    je      .e_enametoolong
    ; default
    mov     rsi, str_err_unknown
    mov     edx, str_err_unknown_len
    ret
.e_eperm:
    mov     rsi, str_err_eperm
    mov     edx, str_err_eperm_len
    ret
.e_enoent:
    mov     rsi, str_err_enoent
    mov     edx, str_err_enoent_len
    ret
.e_eio:
    mov     rsi, str_err_eio
    mov     edx, str_err_eio_len
    ret
.e_eacces:
    mov     rsi, str_err_eacces
    mov     edx, str_err_eacces_len
    ret
.e_eexist:
    mov     rsi, str_err_eexist
    mov     edx, str_err_eexist_len
    ret
.e_exdev:
    mov     rsi, str_err_exdev
    mov     edx, str_err_exdev_len
    ret
.e_enotdir:
    mov     rsi, str_err_enotdir
    mov     edx, str_err_enotdir_len
    ret
.e_eisdir:
    mov     rsi, str_err_eisdir
    mov     edx, str_err_eisdir_len
    ret
.e_enomem:
    mov     rsi, str_err_enomem
    mov     edx, str_err_enomem_len
    ret
.e_erofs:
    mov     rsi, str_err_erofs
    mov     edx, str_err_erofs_len
    ret
.e_emlink:
    mov     rsi, str_err_emlink
    mov     edx, str_err_emlink_len
    ret
.e_enospc:
    mov     rsi, str_err_enospc
    mov     edx, str_err_enospc_len
    ret
.e_eloop:
    mov     rsi, str_err_eloop
    mov     edx, str_err_eloop_len
    ret
.e_enametoolong:
    mov     rsi, str_err_enametoolong
    mov     edx, str_err_enametoolong_len
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
    db "Usage: link FILE1 FILE2", 10
    db "  or:  link OPTION", 10
    db "Call the link function to create a link named FILE2 to an existing FILE1.", 10, 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Report any translation bugs to <https://translationproject.org/team/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/link>", 10
    db "or available locally via: info '(coreutils) link invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "link (GNU coreutils) 9.4", 10
    db "Copyright (C) 2023 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Michael Stone.", 10
str_version_len equ $ - str_version

str_prefix:      db "link: "
str_prefix_len   equ $ - str_prefix
str_extra:       db "extra operand '"
str_extra_len    equ $ - str_extra
str_missing:     db "missing operand", 10
str_missing_len  equ $ - str_missing
str_missing_after: db "missing operand after '"
str_missing_after_len equ $ - str_missing_after
str_sq_nl:       db "'", 10
str_try:         db "Try 'link --help' for more information.", 10
str_try_len      equ $ - str_try
str_cannot_create: db "cannot create link '"
str_cannot_create_len equ $ - str_cannot_create
str_to:          db "' to '"
str_to_len       equ $ - str_to
str_colon_space: db "': "
str_colon_space_len equ $ - str_colon_space
; @@DATA_END@@

; Error messages for errno values
str_err_eperm:       db "Operation not permitted"
str_err_eperm_len    equ $ - str_err_eperm
str_err_enoent:      db "No such file or directory"
str_err_enoent_len   equ $ - str_err_enoent
str_err_eio:         db "Input/output error"
str_err_eio_len      equ $ - str_err_eio
str_err_eacces:      db "Permission denied"
str_err_eacces_len   equ $ - str_err_eacces
str_err_eexist:      db "File exists"
str_err_eexist_len   equ $ - str_err_eexist
str_err_exdev:       db "Invalid cross-device link"
str_err_exdev_len    equ $ - str_err_exdev
str_err_enotdir:     db "Not a directory"
str_err_enotdir_len  equ $ - str_err_enotdir
str_err_eisdir:      db "Is a directory"
str_err_eisdir_len   equ $ - str_err_eisdir
str_err_enomem:      db "Cannot allocate memory"
str_err_enomem_len   equ $ - str_err_enomem
str_err_erofs:       db "Read-only file system"
str_err_erofs_len    equ $ - str_err_erofs
str_err_emlink:      db "Too many links"
str_err_emlink_len   equ $ - str_err_emlink
str_err_enospc:      db "No space left on device"
str_err_enospc_len   equ $ - str_err_enospc
str_err_eloop:       db "Too many levels of symbolic links"
str_err_eloop_len    equ $ - str_err_eloop
str_err_enametoolong: db "File name too long"
str_err_enametoolong_len equ $ - str_err_enametoolong
str_err_unknown:     db "Unknown error"
str_err_unknown_len  equ $ - str_err_unknown

str_newline:     db 10
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0

file_size equ $ - $$
