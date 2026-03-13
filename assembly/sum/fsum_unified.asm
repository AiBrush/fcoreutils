; ============================================================
; fsum_unified.asm — GNU-compatible 'sum' command
; Builds with: nasm -f bin fsum_unified.asm -o fsum
;
; sum: Checksum and count the blocks in a file.
; Uses BSD (default) or SysV algorithm.
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

%define O_RDONLY        0

%define BSS_ADDR    0x500000
%define BSS_SIZE    69632
%define READ_BUF    BSS_ADDR                ; 65536 bytes for read buffer
%define READ_BUF_SZ 65536
%define OUT_BUF     (BSS_ADDR + 65536)      ; 1024 bytes for output formatting
%define OUT_BUF_SZ  1024

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

    ; r12d: flags - bit 0 = sysv mode (0=BSD default, 1=SysV)
    ; r13d: exit code
    xor     r12d, r12d
    xor     r13d, r13d
    mov     ecx, 1              ; arg index

.parse_opts:
    cmp     ecx, r14d
    jge     .done_opts
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .done_opts
    cmp     byte [rdi + 1], 0
    je      .done_opts           ; bare "-" is stdin

    cmp     byte [rdi + 1], '-'
    je      .check_long

    ; Short options: -r, -s
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'r'
    je      .set_bsd
    cmp     al, 's'
    je      .set_sysv
    ; Invalid short option
    push    rcx
    mov     r9, rdi
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    do_write_err
    mov     rsi, r9
    mov     edx, 1
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

.set_bsd:
    and     r12d, ~1            ; clear sysv flag
    inc     rdi
    jmp     .short_loop

.set_sysv:
    or      r12d, 1
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
    ; --sysv
    mov     rdi, r9
    mov     rsi, str_sysv_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_sysv
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

.pop_set_sysv:
    pop     rcx
    or      r12d, 1
    inc     ecx
    jmp     .parse_opts

.double_dash:
    inc     ecx
    jmp     .done_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

.done_opts:
    ; ecx = index of first file arg
    ; If no file args, process stdin (no filename)
    mov     ebp, ecx            ; save first file index
    cmp     ecx, r14d
    jl      .process_files

    ; No file args: read from stdin
    xor     edi, edi            ; fd = stdin
    xor     esi, esi            ; filename = NULL (no filename to print)
    call    process_file
    mov     edi, r13d
    jmp     do_exit

.process_files:
    mov     ebp, ecx            ; current file index
.file_loop:
    cmp     ebp, r14d
    jge     .all_done

    mov     rdi, [r15 + rbp*8]  ; filename

    ; Check if it's "-" (stdin)
    cmp     byte [rdi], '-'
    jne     .open_file
    cmp     byte [rdi + 1], 0
    jne     .open_file
    ; It's "-", read stdin with "-" as display name
    push    rbp
    mov     rsi, rdi            ; filename = "-"
    xor     edi, edi            ; fd = stdin
    call    process_file
    pop     rbp
    inc     ebp
    jmp     .file_loop

.open_file:
    push    rbp
    mov     r9, rdi             ; save filename
    mov     eax, SYS_OPEN
    xor     esi, esi            ; O_RDONLY
    xor     edx, edx            ; mode (unused for O_RDONLY)
    syscall
    test    rax, rax
    js      .open_error

    ; File opened successfully
    mov     edi, eax            ; fd
    mov     rsi, r9             ; filename
    push    rdi                 ; save fd for close
    call    process_file
    pop     rdi                 ; restore fd
    mov     eax, SYS_CLOSE
    syscall

    pop     rbp
    inc     ebp
    jmp     .file_loop

.open_error:
    ; Print error message
    neg     rax                 ; errno
    mov     r8, rax             ; save errno

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

    cmp     r8d, 2              ; ENOENT
    je      .err_enoent
    cmp     r8d, 13             ; EACCES
    je      .err_eacces
    cmp     r8d, 21             ; EISDIR
    je      .err_eisdir
    mov     rsi, str_err_generic
    mov     edx, str_err_generic_len
    jmp     .err_print
.err_enoent:
    mov     rsi, str_enoent
    mov     edx, str_enoent_len
    jmp     .err_print
.err_eacces:
    mov     rsi, str_eacces
    mov     edx, str_eacces_len
    jmp     .err_print
.err_eisdir:
    mov     rsi, str_eisdir
    mov     edx, str_eisdir_len
.err_print:
    call    do_write_err
    mov     r13d, 1             ; set exit code to 1

    pop     rbp
    inc     ebp
    jmp     .file_loop

.all_done:
    mov     edi, r13d
    jmp     do_exit

; ============================================================
; process_file: compute checksum and print result
;   edi = file descriptor
;   rsi = filename pointer (NULL if no filename to print)
; Uses r12d for mode flag (bit 0 = sysv)
; Clobbers many registers, preserves r12, r13, r14, r15
; ============================================================
process_file:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    push    rbx

    mov     ebx, edi            ; fd
    mov     r15, rsi            ; filename (or NULL)

    ; r14 = total bytes read (64-bit)
    xor     r14d, r14d
    ; rbp = checksum (32-bit used, but keep in rbp for easy access)
    xor     ebp, ebp

    test    r12d, 1
    jnz     .pf_sysv_loop

    ; === BSD read loop ===
.pf_bsd_loop:
    mov     eax, SYS_READ
    mov     edi, ebx
    mov     rsi, READ_BUF
    mov     edx, READ_BUF_SZ
    syscall
    cmp     rax, -4             ; EINTR
    je      .pf_bsd_loop
    test    rax, rax
    jle     .pf_bsd_done

    add     r14, rax            ; total bytes
    ; Process buffer: rax bytes at READ_BUF
    mov     rcx, rax            ; byte count
    xor     r8d, r8d            ; buffer index
.pf_bsd_byte:
    cmp     r8, rcx
    jge     .pf_bsd_loop

    ; BSD rotate right: cksum = (cksum >> 1) + ((cksum & 1) << 15)
    mov     eax, ebp
    shr     eax, 1
    mov     edx, ebp
    and     edx, 1
    shl     edx, 15
    add     eax, edx
    ; Add byte
    movzx   edx, byte [READ_BUF + r8]
    add     eax, edx
    and     eax, 0xFFFF
    mov     ebp, eax

    inc     r8
    jmp     .pf_bsd_byte

.pf_bsd_done:
    ; checksum in ebp, total bytes in r14
    ; blocks = ceil(total_bytes / 1024)
    mov     rax, r14
    add     rax, 1023
    shr     rax, 10             ; divide by 1024
    mov     r9, rax             ; blocks

    ; Format BSD output: "%05d %5d filename\n"
    mov     rdi, OUT_BUF
    ; Zero-padded 5-digit checksum
    mov     eax, ebp
    mov     ecx, 5              ; width
    mov     r8d, 1              ; zero-pad flag
    call    format_number
    ; rdi points past last digit
    mov     byte [rdi], ' '
    inc     rdi
    ; Right-justified 5-digit blocks
    mov     rax, r9
    mov     ecx, 5              ; width
    xor     r8d, r8d            ; space-pad
    call    format_number
    jmp     .pf_print_filename

    ; === SysV read loop ===
.pf_sysv_loop:
    mov     eax, SYS_READ
    mov     edi, ebx
    mov     rsi, READ_BUF
    mov     edx, READ_BUF_SZ
    syscall
    cmp     rax, -4             ; EINTR
    je      .pf_sysv_loop
    test    rax, rax
    jle     .pf_sysv_done

    add     r14, rax            ; total bytes
    mov     rcx, rax
    xor     r8d, r8d
.pf_sysv_byte:
    cmp     r8, rcx
    jge     .pf_sysv_loop
    movzx   edx, byte [READ_BUF + r8]
    add     ebp, edx            ; sum += byte (32-bit accumulator)
    inc     r8
    jmp     .pf_sysv_byte

.pf_sysv_done:
    ; Fold to 16 bits: sum = (sum & 0xFFFF) + (sum >> 16)
    mov     eax, ebp
    mov     edx, ebp
    and     eax, 0xFFFF
    shr     edx, 16
    add     eax, edx
    ; Could still overflow 16 bits, fold again
    mov     edx, eax
    and     eax, 0xFFFF
    shr     edx, 16
    add     eax, edx
    mov     ebp, eax            ; final checksum

    ; blocks = ceil(total_bytes / 512)
    mov     rax, r14
    add     rax, 511
    shr     rax, 9              ; divide by 512
    mov     r9, rax             ; blocks

    ; Format SysV output: "%d %d filename\n"
    mov     rdi, OUT_BUF
    ; No padding for checksum
    mov     eax, ebp
    xor     ecx, ecx            ; width 0 = no padding
    xor     r8d, r8d
    call    format_number
    mov     byte [rdi], ' '
    inc     rdi
    ; No padding for blocks
    mov     rax, r9
    xor     ecx, ecx
    xor     r8d, r8d
    call    format_number

.pf_print_filename:
    ; If filename is not NULL, append " filename"
    test    r15, r15
    jz      .pf_no_filename
    mov     byte [rdi], ' '
    inc     rdi
    ; Copy filename
    mov     rsi, r15
.pf_copy_name:
    lodsb
    test    al, al
    jz      .pf_no_filename
    mov     [rdi], al
    inc     rdi
    jmp     .pf_copy_name

.pf_no_filename:
    mov     byte [rdi], 10      ; newline
    inc     rdi

    ; Write output
    mov     rsi, OUT_BUF
    mov     rdx, rdi
    sub     rdx, rsi            ; length
    mov     edi, STDOUT
    call    do_write

    pop     rbx
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

; ============================================================
; format_number: convert integer to ASCII in buffer
;   rax = number to convert
;   rdi = output buffer pointer
;   ecx = minimum width (0 = no minimum)
;   r8d = pad character flag: 1 = '0', 0 = ' '
; Returns: rdi advanced past the last character written
; ============================================================
format_number:
    push    rbx
    push    r9
    push    r12
    push    r13

    mov     r12, rdi            ; save start position
    mov     r13d, ecx           ; save width
    mov     rbx, rax            ; save number

    ; Convert number to digits on stack
    xor     ecx, ecx            ; digit count
    mov     rax, rbx
    test    rax, rax
    jnz     .fn_convert
    ; Number is zero: push one '0'
    push    '0'
    inc     ecx
    jmp     .fn_pad

.fn_convert:
    xor     edx, edx
    mov     r9, 10
    div     r9                  ; rax = quotient, rdx = remainder
    add     edx, '0'
    push    rdx
    inc     ecx
    test    rax, rax
    jnz     .fn_convert

.fn_pad:
    ; ecx = number of digits
    ; r13d = minimum width
    ; Need to pad if ecx < r13d
    mov     eax, r13d
    sub     eax, ecx            ; padding needed
    jle     .fn_write_digits
    ; Write padding characters
    mov     edx, eax            ; pad count
    mov     al, ' '
    test    r8d, r8d
    jz      .fn_pad_loop
    mov     al, '0'
.fn_pad_loop:
    mov     [rdi], al
    inc     rdi
    dec     edx
    jnz     .fn_pad_loop

.fn_write_digits:
    ; Pop digits from stack
    pop     rax
    mov     [rdi], al
    inc     rdi
    dec     ecx
    jnz     .fn_write_digits

    pop     r13
    pop     r12
    pop     r9
    pop     rbx
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

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: sum [OPTION]... [FILE]...", 10
    db "Print or check BSD (16-bit) checksums.", 10
    db "With no FILE, or when FILE is -, read standard input.", 10, 10
    db "  -r              use BSD sum algorithm (default), use 1K blocks", 10
    db "  -s, --sysv      use System V sum algorithm, use 512 bytes blocks", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/sum>", 10
    db "or available locally via: info '(coreutils) sum invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "sum (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Kayvan Aghaiepour and David MacKenzie.", 10
str_version_len equ $ - str_version

str_prefix:      db "sum: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_sq_nl:       db "'", 10
str_try:         db "Try 'sum --help' for more information.", 10
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
str_sysv_flag:   db "--sysv", 0

file_size equ $ - $$
