; ============================================================
; ftee_unified.asm — GNU-compatible 'tee' command
; Builds with: nasm -f bin ftee_unified.asm -o ftee
;
; tee: Read from stdin, write to stdout and files.
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXIT       60
%define SYS_RT_SIGPROCMASK 14

%define STDOUT          1
%define STDERR          2
%define STDIN           0
%define SIG_BLOCK       0
%define SIGPIPE        13
%define SIGINT          2

%define O_WRONLY        1
%define O_CREAT        64
%define O_TRUNC       512
%define O_APPEND      1024

%define BSS_ADDR    0x500000
%define BSS_SIZE    69632        ; 64KB read buffer + 64 file descriptors + scratch
%define READ_BUF    BSS_ADDR
%define READ_BUF_SZ 65536
%define FD_ARRAY    (BSS_ADDR + 65536)  ; up to 64 file descriptors (64*4=256 bytes)
%define MAX_FDS     64

; --- ELF Header ---
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

    mov     r14d, [rsp]         ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Flags: r12d bit 0 = -a (append), bit 1 = -i (ignore interrupts)
    xor     r12d, r12d
    mov     ecx, 1              ; arg index
    xor     ebx, ebx            ; fd count (number of output files)

.parse_opts:
    cmp     ecx, r14d
    jge     .done_opts
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .done_opts
    cmp     byte [rdi + 1], 0
    je      .done_opts           ; bare "-" means stdin, treat as file

    cmp     byte [rdi + 1], '-'
    je      .check_long

    ; Short options: -a, -i (can be combined)
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'a'
    je      .set_append
    cmp     al, 'i'
    je      .set_ignore
    cmp     al, 'p'
    je      .set_p
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

.set_append:
    or      r12d, 1
    inc     rdi
    jmp     .short_loop

.set_ignore:
    or      r12d, 2
    inc     rdi
    jmp     .short_loop

.set_p:
    ; -p flag (warn-nopipe mode) - just accept it
    inc     rdi
    jmp     .short_loop

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
    mov     r9, rdi
    push    rcx
    ; --help
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_help
    ; --version
    mov     rdi, r9
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_version
    ; --append
    mov     rdi, r9
    mov     rsi, str_append_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_append
    ; --ignore-interrupts
    mov     rdi, r9
    mov     rsi, str_ignore_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_ignore
    ; --output-error (accept with or without =MODE)
    mov     rdi, r9
    mov     rsi, str_output_error
    mov     edx, 14             ; "--output-error"
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_next
    ; Unrecognized
    pop     rcx
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_unrecog
    mov     edx, str_unrecog_len
    call    do_write_err
    mov     rdi, r9
    call    str_len
    mov     edx, eax
    mov     rsi, r9
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
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.pop_show_version:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.pop_set_append:
    pop     rcx
    or      r12d, 1
    inc     ecx
    jmp     .parse_opts

.pop_set_ignore:
    pop     rcx
    or      r12d, 2
    inc     ecx
    jmp     .parse_opts

.pop_next:
    pop     rcx
    inc     ecx
    jmp     .parse_opts

.double_dash:
    inc     ecx
    jmp     .done_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

.done_opts:
    ; If -i flag set, also block SIGINT
    test    r12d, 2
    jz      .open_files
    sub     rsp, 16
    mov     qword [rsp], 0
    bts     qword [rsp], SIGINT
    mov     eax, SYS_RT_SIGPROCMASK
    mov     edi, SIG_BLOCK
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

.open_files:
    ; Open output files from argv[ecx..r14d-1]
    xor     ebx, ebx            ; fd count
.open_loop:
    cmp     ecx, r14d
    jge     .read_loop
    cmp     ebx, MAX_FDS
    jge     .read_loop           ; too many files

    mov     rdi, [r15 + rcx*8]
    push    rcx                 ; save arg index (syscall clobbers rcx)

    ; Set flags: O_WRONLY | O_CREAT | (O_TRUNC or O_APPEND)
    mov     esi, O_WRONLY
    or      esi, O_CREAT
    test    r12d, 1
    jnz     .use_append
    or      esi, O_TRUNC
    jmp     .do_open
.use_append:
    or      esi, O_APPEND
.do_open:
    mov     edx, 0666o          ; mode
    mov     eax, SYS_OPEN
    syscall
    pop     rcx                 ; restore arg index
    test    rax, rax
    js      .open_error
    ; Store fd
    mov     [FD_ARRAY + rbx*4], eax
    inc     ebx
    inc     ecx
    jmp     .open_loop

.open_error:
    ; Save error for reporting
    push    rcx
    push    rbx
    neg     rax                 ; errno
    mov     r13, rax            ; save errno
    mov     rdi, [r15 + rcx*8]  ; filename
    mov     r9, rdi             ; save filename

    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rdi, r9
    call    str_len
    mov     edx, eax
    mov     rsi, r9
    call    do_write_err
    mov     rsi, str_open_fail
    mov     edx, str_open_fail_len
    call    do_write_err

    ; Map errno to message
    cmp     r13d, 2              ; ENOENT
    je      .open_enoent
    cmp     r13d, 13             ; EACCES
    je      .open_eacces
    cmp     r13d, 21             ; EISDIR
    je      .open_eisdir
    ; Default
    mov     rsi, str_err_generic
    mov     edx, str_err_generic_len
    jmp     .open_err_print
.open_enoent:
    mov     rsi, str_enoent
    mov     edx, str_enoent_len
    jmp     .open_err_print
.open_eacces:
    mov     rsi, str_eacces
    mov     edx, str_eacces_len
    jmp     .open_err_print
.open_eisdir:
    mov     rsi, str_eisdir
    mov     edx, str_eisdir_len
.open_err_print:
    call    do_write_err
    pop     rbx
    pop     rcx
    inc     ecx
    jmp     .open_loop

.read_loop:
    ; r12d = flags, ebx = fd count
    ; Read from stdin, write to stdout and all files
    mov     eax, SYS_READ
    xor     edi, edi            ; stdin
    mov     rsi, READ_BUF
    mov     edx, READ_BUF_SZ
    syscall

    cmp     rax, -4             ; EINTR
    je      .read_loop
    test    rax, rax
    jle     .close_files        ; EOF or error

    mov     r13, rax            ; bytes read

    ; Write to stdout
    mov     edi, STDOUT
    mov     rsi, READ_BUF
    mov     rdx, r13
    call    do_write

    ; Write to each output file
    xor     ecx, ecx
.write_files:
    cmp     ecx, ebx
    jge     .read_loop
    push    rcx
    push    rbx
    mov     edi, [FD_ARRAY + rcx*4]
    mov     rsi, READ_BUF
    mov     rdx, r13
    call    do_write
    pop     rbx
    pop     rcx
    inc     ecx
    jmp     .write_files

.close_files:
    ; Close all output files
    xor     ecx, ecx
.close_loop:
    cmp     ecx, ebx
    jge     .exit_ok
    push    rcx
    push    rbx
    mov     edi, [FD_ARRAY + rcx*4]
    mov     eax, SYS_CLOSE
    syscall
    pop     rbx
    pop     rcx
    inc     ecx
    jmp     .close_loop

.exit_ok:
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
    db "Usage: tee [OPTION]... [FILE]...", 10
    db "Copy standard input to each FILE, and also to standard output.", 10, 10
    db "  -a, --append              append to the given FILEs, do not overwrite", 10
    db "  -i, --ignore-interrupts   ignore interrupt signals", 10
    db "  -p                        operate in a more appropriate MODE with pipes.", 10
    db "      --output-error[=MODE]   set behavior on write error.  See MODE below", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/tee>", 10
    db "or available locally via: info '(coreutils) tee invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "tee (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Mike Parker, Richard M. Stallman, and David MacKenzie.", 10
str_version_len equ $ - str_version

str_prefix:      db "tee: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_sq_nl:       db "'", 10
str_try:         db "Try 'tee --help' for more information.", 10
str_try_len      equ $ - str_try
str_open_fail:   db ": "
str_open_fail_len equ $ - str_open_fail
str_enoent:      db "No such file or directory", 10
str_enoent_len   equ $ - str_enoent
str_eacces:      db "Permission denied", 10
str_eacces_len   equ $ - str_eacces
str_eisdir:      db "Is a directory", 10
str_eisdir_len   equ $ - str_eisdir
str_err_generic: db "Input/output error", 10
str_err_generic_len equ $ - str_err_generic
; @@DATA_END@@

str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_append_flag: db "--append", 0
str_ignore_flag: db "--ignore-interrupts", 0
str_output_error: db "--output-error", 0

file_size equ $ - $$
