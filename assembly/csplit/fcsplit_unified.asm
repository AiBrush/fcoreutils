; ============================================================
; fcsplit_unified.asm — GNU-compatible 'csplit' command
; Builds with: nasm -f bin fcsplit_unified.asm -o fcsplit
;
; csplit: Split a file into sections determined by context lines.
; Supports: line-number patterns, -f PREFIX, -n DIGITS, -k, -z, -s
; Note: Regexp patterns are delegated to Rust implementation;
;       this assembly version handles numeric split points.
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXIT       60
%define SYS_UNLINK      87
%define SYS_RT_SIGPROCMASK 14

%define STDIN           0
%define STDOUT          1
%define STDERR          2
%define O_RDONLY        0
%define O_WRONLY        1
%define O_CREAT         64
%define O_TRUNC         512
%define FILE_MODE       0o644
%define EINTR           4
%define SIG_BLOCK       0
%define SIGPIPE         13

; BSS layout
%define BSS_BASE     0x500000
%define IO_SIZE      65536
%define io_buf       BSS_BASE
%define line_buf     (io_buf + IO_SIZE)
%define LINE_BUF_SZ  65536
%define fname_buf    (line_buf + LINE_BUF_SZ)
%define num_buf      (fname_buf + 4096)
%define prefix_buf   (num_buf + 128)
%define PREFIX_MAX   256
%define argc_save    (prefix_buf + PREFIX_MAX)
%define argv_save    (argc_save + 8)
%define input_fd     (argv_save + 8)
%define out_fd       (input_fd + 8)
%define file_index   (out_fd + 8)
%define cur_line     (file_index + 8)
%define n_digits     (cur_line + 8)
%define flag_keep    (n_digits + 8)
%define flag_elide   (flag_keep + 4)
%define flag_quiet   (flag_elide + 4)
%define out_bytes    (flag_quiet + 4)
%define patterns     (out_bytes + 8)
%define n_patterns   (patterns + 512)
%define buf_pos      (n_patterns + 8)
%define buf_len      (buf_pos + 8)
%define created_files (buf_len + 8)
%define created_count (created_files + 512)
%define BSS_END      (created_count + 8)
%define BSS_SIZE     (BSS_END - BSS_BASE)

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
    dd 1, 5
    dq 0, $$, $$, file_size, file_size, 0x200000

    dd 1, 6
    dq 0, BSS_BASE, BSS_BASE, 0, BSS_SIZE, 0x200000

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

    ; Defaults
    mov     qword [n_digits], 2
    mov     dword [flag_keep], 0
    mov     dword [flag_elide], 0
    mov     dword [flag_quiet], 0
    mov     qword [file_index], 0
    mov     qword [cur_line], 1
    mov     qword [n_patterns], 0
    mov     qword [buf_pos], 0
    mov     qword [buf_len], 0
    mov     qword [out_bytes], 0
    mov     qword [created_count], 0

    ; Default prefix = "xx"
    mov     word [prefix_buf], 'xx'
    mov     byte [prefix_buf + 2], 0

    mov     r14d, [rsp]         ; argc
    lea     r15, [rsp + 8]      ; argv
    mov     ecx, 1

    ; We need at least FILE and one PATTERN
    cmp     r14d, 2
    jl      .err_usage

.parse_opts:
    cmp     ecx, r14d
    jge     .err_usage
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .done_opts
    cmp     byte [rdi + 1], 0
    je      .done_opts          ; bare "-" = stdin

    cmp     byte [rdi + 1], '-'
    je      .check_long

    ; Short options
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'f'
    je      .set_prefix
    cmp     al, 'n'
    je      .set_digits
    cmp     al, 'k'
    je      .set_keep
    cmp     al, 'z'
    je      .set_elide
    cmp     al, 's'
    je      .set_quiet
    cmp     al, 'b'
    je      .set_suffix_format
    ; Invalid option
    mov     rsi, str_prefix_msg
    mov     edx, str_prefix_msg_len
    call    do_write_err
    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    do_write_err
    mov     rsi, rdi
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

.set_prefix:
    inc     ecx
    cmp     ecx, r14d
    jge     .err_missing_arg
    inc     ecx
    mov     rdi, [r15 + rcx*8 - 8]
    ; Copy prefix
    mov     rsi, rdi
    lea     rdi, [prefix_buf]
    xor     r8d, r8d
.cp_prefix:
    movzx   eax, byte [rsi + r8]
    mov     [rdi + r8], al
    test    al, al
    jz      .parse_opts
    inc     r8d
    cmp     r8d, PREFIX_MAX - 1
    jl      .cp_prefix
    mov     byte [rdi + r8], 0
    jmp     .parse_opts

.set_digits:
    inc     ecx
    cmp     ecx, r14d
    jge     .err_missing_arg
    inc     ecx
    mov     rdi, [r15 + rcx*8 - 8]
    push    rcx
    call    parse_num
    pop     rcx
    mov     [n_digits], rax
    jmp     .parse_opts

.set_keep:
    or      dword [flag_keep], 1
    inc     rdi
    jmp     .short_loop

.set_elide:
    or      dword [flag_elide], 1
    inc     rdi
    jmp     .short_loop

.set_quiet:
    or      dword [flag_quiet], 1
    inc     rdi
    jmp     .short_loop

.set_suffix_format:
    ; -b SUFFIX — accept but ignore (we use numeric suffixes)
    inc     ecx
    cmp     ecx, r14d
    jge     .err_missing_arg
    inc     ecx
    jmp     .parse_opts

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
    mov     r9, rdi
    push    rcx
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_help
    mov     rdi, r9
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_version
    mov     rdi, r9
    mov     rsi, str_quiet_long
    call    str_eq
    test    eax, eax
    jnz     .pop_set_quiet
    mov     rdi, r9
    mov     rsi, str_silent_long
    call    str_eq
    test    eax, eax
    jnz     .pop_set_quiet
    pop     rcx
    ; Unrecognized long option
    mov     rsi, str_prefix_msg
    mov     edx, str_prefix_msg_len
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

.pop_set_quiet:
    pop     rcx
    or      dword [flag_quiet], 1
    inc     ecx
    jmp     .parse_opts

.double_dash:
    inc     ecx
    jmp     .done_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

.done_opts:
    ; argv[ecx] = input file, argv[ecx+1..] = patterns
    cmp     ecx, r14d
    jge     .err_usage

    ; Open input file
    mov     rdi, [r15 + rcx*8]
    ; Check for "-" meaning stdin
    cmp     byte [rdi], '-'
    jne     .open_file
    cmp     byte [rdi + 1], 0
    je      .use_stdin

.open_file:
    push    rcx                 ; save arg index (syscall clobbers rcx)
    mov     esi, O_RDONLY
    xor     edx, edx
    mov     eax, SYS_OPEN
    syscall
    pop     rcx                 ; restore arg index
    test    rax, rax
    js      .err_open
    mov     [input_fd], rax
    jmp     .collect_patterns

.use_stdin:
    mov     qword [input_fd], STDIN

.collect_patterns:
    ; Remaining args after file are patterns
    inc     ecx
    cmp     ecx, r14d
    jge     .err_usage          ; need at least one pattern

    ; Store pattern line numbers (only numeric patterns supported in asm)
    xor     ebx, ebx            ; pattern count
.pat_loop:
    cmp     ecx, r14d
    jge     .patterns_done
    mov     rdi, [r15 + rcx*8]
    ; Check if numeric
    movzx   eax, byte [rdi]
    cmp     al, '0'
    jb      .pat_skip           ; skip non-numeric (regex) patterns
    cmp     al, '9'
    ja      .pat_skip
    push    rcx
    push    rbx
    call    parse_num
    pop     rbx
    pop     rcx
    mov     [patterns + rbx*8], rax
    inc     ebx
    inc     ecx
    jmp     .pat_loop
.pat_skip:
    inc     ecx
    jmp     .pat_loop

.patterns_done:
    mov     [n_patterns], rbx
    test    rbx, rbx
    jz      .err_usage

    ; Process: split at each pattern line number
    xor     r12d, r12d          ; pattern index

    ; Open first output file
    call    open_next_file

.main_loop:
    ; Read a line from input
    call    read_line
    test    rax, rax
    jz      .eof                ; EOF

    ; Check if current line matches next pattern
    cmp     r12d, [n_patterns]
    jge     .write_line         ; no more patterns, write remaining

    mov     rbx, [patterns + r12*8]
    cmp     qword [cur_line], rbx
    jl      .write_line

    ; Pattern matched — close current file, open next
    call    close_print_current
    call    open_next_file
    inc     r12d

.write_line:
    ; Write line to current output file
    mov     eax, SYS_WRITE
    mov     rdi, [out_fd]
    mov     rsi, line_buf
    mov     rdx, [buf_len]
    syscall
    cmp     rax, -EINTR
    je      .write_line
    add     qword [out_bytes], rax

    inc     qword [cur_line]
    jmp     .main_loop

.eof:
    ; Close last output file
    call    close_print_current

    ; Close input file
    mov     rax, [input_fd]
    cmp     rax, STDIN
    je      .exit_ok
    mov     rdi, rax
    mov     eax, SYS_CLOSE
    syscall

.exit_ok:
    xor     edi, edi
    jmp     do_exit

.err_usage:
    mov     rsi, str_prefix_msg
    mov     edx, str_prefix_msg_len
    call    do_write_err
    mov     rsi, str_usage_err
    mov     edx, str_usage_err_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.err_open:
    mov     rsi, str_prefix_msg
    mov     edx, str_prefix_msg_len
    call    do_write_err
    mov     rsi, str_open_fail
    mov     edx, str_open_fail_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.err_missing_arg:
    mov     rsi, str_prefix_msg
    mov     edx, str_prefix_msg_len
    call    do_write_err
    mov     rsi, str_missing_arg
    mov     edx, str_missing_arg_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; ============================================================
; open_next_file: create output file with prefix+index
; ============================================================
open_next_file:
    push    r12
    push    r13

    ; Build filename: prefix + zero-padded index
    lea     rdi, [fname_buf]
    lea     rsi, [prefix_buf]
    ; Copy prefix
    xor     ecx, ecx
.onf_cp:
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .onf_pad
    mov     [rdi + rcx], al
    inc     ecx
    jmp     .onf_cp

.onf_pad:
    ; Now write zero-padded number at [rdi + rcx]
    push    rcx                 ; save prefix length
    mov     rax, [file_index]
    ; Convert number to decimal (reverse)
    lea     r13, [num_buf + 63]
    mov     byte [r13], 0
    mov     r12, 10
    test    rax, rax
    jnz     .onf_digits
    dec     r13
    mov     byte [r13], '0'
    jmp     .onf_pad_zeros
.onf_digits:
    test    rax, rax
    jz      .onf_pad_zeros
    xor     edx, edx
    div     r12
    add     dl, '0'
    dec     r13
    mov     [r13], dl
    jmp     .onf_digits

.onf_pad_zeros:
    ; Calculate digit count
    lea     rax, [num_buf + 63]
    sub     rax, r13
    ; Pad with leading zeros if needed
    mov     rbx, [n_digits]
    pop     rcx                 ; restore prefix length
.onf_zpad:
    cmp     rax, rbx
    jge     .onf_copy_digits
    mov     byte [rdi + rcx], '0'
    inc     ecx
    inc     rax
    jmp     .onf_zpad

.onf_copy_digits:
    ; Copy digit string
.onf_cpy:
    movzx   eax, byte [r13]
    test    al, al
    jz      .onf_open
    mov     [rdi + rcx], al
    inc     r13
    inc     ecx
    jmp     .onf_cpy

.onf_open:
    mov     byte [rdi + rcx], 0
    ; Open the file
    mov     rdi, fname_buf
    mov     esi, (O_WRONLY | O_CREAT | O_TRUNC)
    mov     edx, FILE_MODE
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .onf_err
    mov     [out_fd], rax
    mov     qword [out_bytes], 0
    inc     qword [file_index]

    pop     r13
    pop     r12
    ret

.onf_err:
    mov     rsi, str_prefix_msg
    mov     edx, str_prefix_msg_len
    call    do_write_err
    mov     rsi, str_create_fail
    mov     edx, str_create_fail_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; ============================================================
; close_print_current: close current output file, print size
; ============================================================
close_print_current:
    push    r12
    mov     rdi, [out_fd]
    mov     eax, SYS_CLOSE
    syscall

    ; Print size to stdout (unless -s/--quiet)
    cmp     dword [flag_quiet], 0
    jne     .cpc_check_elide

    mov     rdi, [out_bytes]
    call    itoa
    mov     rsi, num_buf
    mov     edx, eax
    mov     edi, STDOUT
    call    do_write
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write

.cpc_check_elide:
    ; -z: remove empty output files
    cmp     dword [flag_elide], 0
    je      .cpc_done
    cmp     qword [out_bytes], 0
    jne     .cpc_done
    ; Unlink the empty file
    mov     rdi, fname_buf
    mov     eax, SYS_UNLINK
    syscall

.cpc_done:
    pop     r12
    ret

; ============================================================
; read_line: read one line from input into line_buf
; Returns: rax = bytes read (0 = EOF)
; Sets [buf_len] = length including newline
; ============================================================
read_line:
    push    r12
    push    r13
    xor     r12d, r12d          ; position in line_buf

.rl_loop:
    cmp     r12d, LINE_BUF_SZ - 1
    jge     .rl_done            ; line too long, return what we have

    ; Read one byte at a time (simple but correct)
    mov     eax, SYS_READ
    mov     rdi, [input_fd]
    lea     rsi, [line_buf + r12]
    mov     edx, 1
    syscall
    cmp     rax, -EINTR
    je      .rl_loop
    test    rax, rax
    jle     .rl_eof

    inc     r12d
    cmp     byte [line_buf + r12 - 1], 10  ; newline?
    je      .rl_done
    jmp     .rl_loop

.rl_done:
    mov     [buf_len], r12
    mov     rax, r12
    pop     r13
    pop     r12
    ret

.rl_eof:
    ; Return what we have (could be partial line)
    mov     [buf_len], r12
    mov     rax, r12
    pop     r13
    pop     r12
    ret

; ============================================================
; parse_num: parse decimal number from string
; Input: rdi = string; Output: rax = value
; ============================================================
parse_num:
    xor     rax, rax
.pn_loop:
    movzx   ecx, byte [rdi]
    cmp     cl, '0'
    jb      .pn_done
    cmp     cl, '9'
    ja      .pn_done
    imul    rax, 10
    sub     cl, '0'
    movzx   ecx, cl
    add     rax, rcx
    inc     rdi
    jmp     .pn_loop
.pn_done:
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

itoa:
    push    rbx
    push    rcx
    mov     rax, rdi
    lea     rbx, [num_buf + 63]
    mov     byte [rbx], 0
    mov     rcx, 10
    test    rax, rax
    jnz     .itoa_loop
    dec     rbx
    mov     byte [rbx], '0'
    jmp     .itoa_done
.itoa_loop:
    test    rax, rax
    jz      .itoa_done
    xor     edx, edx
    div     rcx
    add     dl, '0'
    dec     rbx
    mov     [rbx], dl
    jmp     .itoa_loop
.itoa_done:
    lea     rsi, [rbx]
    mov     rdi, num_buf
    lea     eax, [num_buf + 63]
    sub     eax, ebx
    mov     ecx, eax
    push    rax
    rep     movsb
    pop     rax
    pop     rcx
    pop     rbx
    ret

; ============================================================
; Data
; ============================================================
str_help:
    db "Usage: csplit [OPTION]... FILE PATTERN...", 10
    db "Output pieces of FILE separated by PATTERN(s) to files 'xx00', 'xx01', ...,", 10
    db "and output byte counts of each piece to standard output.", 10, 10
    db "  -b, --suffix-format=FORMAT  use sprintf FORMAT instead of %02d", 10
    db "  -f, --prefix=PREFIX  use PREFIX instead of 'xx'", 10
    db "  -k, --keep-files     do not remove output files on errors", 10
    db "      --suppress-matched  suppress the lines matching PATTERN", 10
    db "  -n, --digits=DIGITS  use specified number of digits instead of 2", 10
    db "  -s, --quiet, --silent  do not print counts of output file sizes", 10
    db "  -z, --elide-empty-files  suppress empty output files", 10
    db "      --help     display this help and exit", 10
    db "      --version  output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/csplit>", 10
    db "or available locally via: info '(coreutils) csplit invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "csplit (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Stuart Kemp and David MacKenzie.", 10
str_version_len equ $ - str_version

str_prefix_msg:  db "csplit: "
str_prefix_msg_len equ $ - str_prefix_msg
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_sq_nl:       db "'", 10
str_try:         db "Try 'csplit --help' for more information.", 10
str_try_len      equ $ - str_try
str_create_fail: db "cannot create output file", 10
str_create_fail_len equ $ - str_create_fail
str_newline:     db 10

str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_quiet_long:  db "--quiet", 0
str_silent_long: db "--silent", 0

str_usage_err:   db "missing operand", 10
str_usage_err_len equ $ - str_usage_err
str_open_fail:   db "cannot open input file", 10
str_open_fail_len equ $ - str_open_fail
str_missing_arg: db "option requires an argument", 10
str_missing_arg_len equ $ - str_missing_arg

file_size equ $ - $$
