; ============================================================
; ftruncate_unified.asm — GNU-compatible 'truncate' command
; Builds with: nasm -f bin ftruncate_unified.asm -o ftruncate
;
; truncate: Shrink or extend the size of a file to the specified size.
;
; Register allocation:
;   r14d = argc, r15 = argv
;   rbx  = target size (absolute bytes)
;   r12d = flags (bit 0 = -c/no-create, bit 1 = size set, bit 2 = relative +, bit 3 = relative -)
;   r13  = file arg index during file loop
;   rbp  = saved for reference file path
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_FSTAT           5
%define SYS_EXIT           60
%define SYS_FTRUNCATE      77
%define SYS_RT_SIGPROCMASK 14

%define STDOUT              1
%define STDERR              2
%define SIG_BLOCK           0
%define SIGPIPE            13

%define O_RDONLY            0
%define O_WRONLY            1
%define O_CREAT            64
%define MODE_0666        0x1B6

%define FLAG_NO_CREATE      1
%define FLAG_SIZE_SET       2
%define FLAG_REL_PLUS       4
%define FLAG_REL_MINUS      8

; struct stat offsets (x86-64 Linux)
%define STAT_SIZE_OFF      48    ; st_size offset in struct stat

%define BSS_ADDR        0x500000
%define BSS_SIZE        4096
%define STAT_BUF        BSS_ADDR          ; 144 bytes for struct stat
%define NUM_BUF         (BSS_ADDR + 160)  ; 32 bytes for number conversion

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

    xor     r12d, r12d          ; flags
    xor     ebx, ebx            ; target size
    xor     ebp, ebp            ; reference file ptr (0 = none)
    mov     ecx, 1              ; arg index

.parse_opts:
    cmp     ecx, r14d
    jge     .done_opts
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .done_opts
    cmp     byte [rdi + 1], 0
    je      .done_opts          ; bare "-" is a filename
    cmp     byte [rdi + 1], '-'
    je      .check_long

    ; Short options
    inc     rdi                 ; skip '-'
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'c'
    je      .set_no_create
    cmp     al, 's'
    je      .set_size_short
    cmp     al, 'r'
    je      .set_ref_short
    ; Invalid short option
    mov     r9, rdi
    push    rcx
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

.set_no_create:
    or      r12d, FLAG_NO_CREATE
    inc     rdi
    jmp     .short_loop

.set_size_short:
    inc     rdi
    cmp     byte [rdi], 0
    jne     .parse_size_value
    ; Size is the next argument
    inc     ecx
    cmp     ecx, r14d
    jge     .err_opt_requires_arg_s
    mov     rdi, [r15 + rcx*8]
    jmp     .parse_size_value

.set_ref_short:
    inc     rdi
    cmp     byte [rdi], 0
    jne     .set_ref_inline
    ; Reference file is next argument
    inc     ecx
    cmp     ecx, r14d
    jge     .err_opt_requires_arg_r
    mov     rbp, [r15 + rcx*8]
    jmp     .next_opt

.set_ref_inline:
    mov     rbp, rdi
    jmp     .next_opt

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

    ; --no-create
    mov     rdi, r9
    mov     rsi, str_no_create_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_no_create

    ; --size=
    mov     rdi, r9
    mov     rsi, str_size_prefix
    mov     edx, 7              ; "--size="
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_size_long

    ; --reference=
    mov     rdi, r9
    mov     rsi, str_ref_prefix
    mov     edx, 12             ; "--reference="
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_ref_long

    ; Unrecognized long option
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

.pop_set_no_create:
    pop     rcx
    or      r12d, FLAG_NO_CREATE
    jmp     .next_opt

.pop_set_size_long:
    pop     rcx
    lea     rdi, [r9 + 7]      ; skip "--size="
    jmp     .parse_size_value

.pop_set_ref_long:
    pop     rcx
    lea     rbp, [r9 + 12]     ; skip "--reference="
    jmp     .next_opt

.double_dash:
    inc     ecx
    jmp     .done_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

.err_opt_requires_arg_s:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_opt_req_s
    mov     edx, str_opt_req_s_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.err_opt_requires_arg_r:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_opt_req_r
    mov     edx, str_opt_req_r_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; --- Parse size value ---
; rdi = pointer to size string (may have +/- prefix, suffix K/M/G/T/KB/MB/GB/TB)
.parse_size_value:
    or      r12d, FLAG_SIZE_SET
    ; Check for +/- prefix
    movzx   eax, byte [rdi]
    cmp     al, '+'
    je      .size_rel_plus
    cmp     al, '-'
    je      .size_rel_minus
    jmp     .size_parse_digits

.size_rel_plus:
    or      r12d, FLAG_REL_PLUS
    inc     rdi
    jmp     .size_parse_digits

.size_rel_minus:
    or      r12d, FLAG_REL_MINUS
    inc     rdi

.size_parse_digits:
    ; Parse decimal number from rdi into rbx
    xor     rbx, rbx
    movzx   eax, byte [rdi]
    cmp     al, '0'
    jb      .err_invalid_number
    cmp     al, '9'
    ja      .err_invalid_number

.digit_loop:
    movzx   eax, byte [rdi]
    sub     eax, '0'
    js      .size_check_suffix
    cmp     eax, 9
    jg      .size_check_suffix
    imul    rbx, 10
    add     rbx, rax
    inc     rdi
    jmp     .digit_loop

.size_check_suffix:
    ; Check what's after the digits
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt           ; no suffix, done

    cmp     al, 'K'
    je      .suffix_K
    cmp     al, 'M'
    je      .suffix_M
    cmp     al, 'G'
    je      .suffix_G
    cmp     al, 'T'
    je      .suffix_T
    cmp     al, 'k'
    je      .suffix_K
    cmp     al, 'm'
    je      .suffix_M_lower
    cmp     al, 'g'
    je      .suffix_G_lower
    cmp     al, 't'
    je      .suffix_T_lower
    ; Unknown suffix
    jmp     .err_invalid_number

.suffix_K:
    ; K or KB?
    cmp     byte [rdi + 1], 'B'
    je      .suffix_KB
    ; K = 1024
    imul    rbx, 1024
    ; check next byte is 0
    cmp     byte [rdi + 1], 0
    jne     .err_invalid_number
    jmp     .next_opt

.suffix_KB:
    cmp     byte [rdi + 2], 0
    jne     .err_invalid_number
    imul    rbx, 1000
    jmp     .next_opt

.suffix_M:
    cmp     byte [rdi + 1], 'B'
    je      .suffix_MB
    imul    rbx, 1048576
    cmp     byte [rdi + 1], 0
    jne     .err_invalid_number
    jmp     .next_opt

.suffix_MB:
    cmp     byte [rdi + 2], 0
    jne     .err_invalid_number
    imul    rbx, 1000000
    jmp     .next_opt

.suffix_G:
    cmp     byte [rdi + 1], 'B'
    je      .suffix_GB
    imul    rbx, 1073741824
    cmp     byte [rdi + 1], 0
    jne     .err_invalid_number
    jmp     .next_opt

.suffix_GB:
    cmp     byte [rdi + 2], 0
    jne     .err_invalid_number
    imul    rbx, 1000000000
    jmp     .next_opt

.suffix_T:
    cmp     byte [rdi + 1], 'B'
    je      .suffix_TB
    mov     rax, 1099511627776
    imul    rbx, rax
    cmp     byte [rdi + 1], 0
    jne     .err_invalid_number
    jmp     .next_opt

.suffix_TB:
    cmp     byte [rdi + 2], 0
    jne     .err_invalid_number
    mov     rax, 1000000000000
    imul    rbx, rax
    jmp     .next_opt

; Lowercase suffixes (same as uppercase binary)
.suffix_M_lower:
    imul    rbx, 1048576
    cmp     byte [rdi + 1], 0
    jne     .err_invalid_number
    jmp     .next_opt
.suffix_G_lower:
    imul    rbx, 1073741824
    cmp     byte [rdi + 1], 0
    jne     .err_invalid_number
    jmp     .next_opt
.suffix_T_lower:
    mov     rax, 1099511627776
    imul    rbx, rax
    cmp     byte [rdi + 1], 0
    jne     .err_invalid_number
    jmp     .next_opt

.err_invalid_number:
    ; Save the original size arg pointer - we need to go back
    ; We'll print a generic error since we lost the original pointer
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid_num
    mov     edx, str_invalid_num_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.done_opts:
    ; Save ecx (file arg index) — syscalls clobber rcx
    mov     r9d, ecx

    ; If reference file specified, get its size
    test    rbp, rbp
    jz      .check_size_required

    ; Open reference file
    mov     eax, SYS_OPEN
    mov     rdi, rbp
    xor     esi, esi            ; O_RDONLY
    xor     edx, edx
    syscall
    test    rax, rax
    js      .err_ref_open
    mov     r8d, eax            ; fd

    ; fstat
    mov     eax, SYS_FSTAT
    mov     edi, r8d
    mov     rsi, STAT_BUF
    syscall
    test    rax, rax
    js      .err_ref_stat

    ; Get size from stat
    mov     rax, [STAT_BUF + STAT_SIZE_OFF]

    ; Close reference file
    push    rax
    mov     eax, SYS_CLOSE
    mov     edi, r8d
    syscall
    pop     rax

    ; If -s not set, use reference size directly
    test    r12d, FLAG_SIZE_SET
    jnz     .ref_with_size
    ; Use reference size as the target
    mov     rbx, rax
    or      r12d, FLAG_SIZE_SET
    jmp     .check_files

.ref_with_size:
    ; -s was set with relative modifier and -r was set
    ; The relative size applies to the reference size
    test    r12d, FLAG_REL_PLUS
    jnz     .ref_rel_plus
    test    r12d, FLAG_REL_MINUS
    jnz     .ref_rel_minus
    ; Absolute size overrides reference
    jmp     .check_files

.ref_rel_plus:
    add     rbx, rax
    ; Clear relative flags, now it's absolute
    and     r12d, ~(FLAG_REL_PLUS | FLAG_REL_MINUS)
    jmp     .check_files

.ref_rel_minus:
    ; reference_size - size
    sub     rax, rbx
    jns     .ref_minus_ok
    xor     eax, eax            ; clamp to 0
.ref_minus_ok:
    mov     rbx, rax
    and     r12d, ~(FLAG_REL_PLUS | FLAG_REL_MINUS)
    jmp     .check_files

.err_ref_open:
    push    rcx
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_stat
    mov     edx, str_cannot_stat_len
    call    do_write_err
    mov     rdi, rbp
    call    str_len
    mov     edx, eax
    mov     rsi, rbp
    call    do_write_err
    mov     rsi, str_no_such
    mov     edx, str_no_such_len
    call    do_write_err
    pop     rcx
    mov     edi, 1
    jmp     do_exit

.err_ref_stat:
    ; Close fd first
    push    r8
    mov     eax, SYS_CLOSE
    mov     edi, r8d
    syscall
    pop     r8
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_stat
    mov     edx, str_cannot_stat_len
    call    do_write_err
    mov     rdi, rbp
    call    str_len
    mov     edx, eax
    mov     rsi, rbp
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.check_size_required:
    ; If neither -s nor -r was given, error
    test    r12d, FLAG_SIZE_SET
    jz      .err_missing_size

.check_files:
    ; r9d = first file arg index (ecx was saved to r9d, syscalls clobber rcx)
    cmp     r9d, r14d
    jge     .err_missing_operand

    ; Process files
    mov     r13d, r9d
    xor     ebp, ebp            ; reuse ebp as exit code

.file_loop:
    cmp     r13d, r14d
    jge     .exit_with_code
    mov     rdi, [r15 + r13*8]
    call    do_truncate_file
    inc     r13d
    jmp     .file_loop

.exit_with_code:
    mov     edi, ebp
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

.err_missing_size:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_must_specify
    mov     edx, str_must_specify_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; ============================================================
; do_truncate_file: truncate one file
; Input: rdi = filename pointer
;   rbx = target size, r12d = flags
;   ebp = exit code accumulator
; ============================================================
do_truncate_file:
    push    r13
    push    r14
    push    r15
    mov     r13, rdi            ; save filename

    ; Determine open flags
    mov     esi, O_WRONLY
    test    r12d, FLAG_NO_CREATE
    jnz     .tf_no_create_open
    or      esi, O_CREAT
.tf_no_create_open:

    ; Open file
    mov     eax, SYS_OPEN
    mov     rdi, r13
    mov     edx, MODE_0666
    syscall
    test    rax, rax
    js      .tf_open_err
    mov     r14d, eax           ; fd

    ; If relative mode, need current file size via fstat
    mov     r15, rbx            ; final size = target
    test    r12d, FLAG_REL_PLUS | FLAG_REL_MINUS
    jz      .tf_do_truncate

    ; fstat to get current size
    mov     eax, SYS_FSTAT
    mov     edi, r14d
    mov     rsi, STAT_BUF
    syscall
    test    rax, rax
    js      .tf_stat_err

    mov     rax, [STAT_BUF + STAT_SIZE_OFF]  ; current size

    test    r12d, FLAG_REL_PLUS
    jnz     .tf_rel_plus
    ; FLAG_REL_MINUS
    sub     rax, rbx
    jns     .tf_rel_set
    xor     eax, eax            ; clamp to 0
    jmp     .tf_rel_set

.tf_rel_plus:
    add     rax, rbx

.tf_rel_set:
    mov     r15, rax            ; final size

.tf_do_truncate:
    ; ftruncate(fd, size)
    mov     eax, SYS_FTRUNCATE
    mov     edi, r14d
    mov     rsi, r15
    syscall
    test    rax, rax
    js      .tf_trunc_err

    ; Close
    mov     eax, SYS_CLOSE
    mov     edi, r14d
    syscall

    pop     r15
    pop     r14
    pop     r13
    ret

.tf_open_err:
    ; Check if -c flag and file doesn't exist: silently skip
    test    r12d, FLAG_NO_CREATE
    jnz     .tf_skip_silent

    push    rbp
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_open1
    mov     edx, str_cannot_open1_len
    call    do_write_err
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err
    mov     rsi, str_cannot_open2
    mov     edx, str_cannot_open2_len
    call    do_write_err
    pop     rbp
    mov     ebp, 1              ; set exit code to 1
    pop     r15
    pop     r14
    pop     r13
    ret

.tf_skip_silent:
    pop     r15
    pop     r14
    pop     r13
    ret

.tf_stat_err:
.tf_trunc_err:
    ; Close fd and report error
    push    rax
    mov     eax, SYS_CLOSE
    mov     edi, r14d
    syscall
    pop     rax

    push    rbp
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_failed_trunc1
    mov     edx, str_failed_trunc1_len
    call    do_write_err
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err
    mov     rsi, str_failed_trunc2
    mov     edx, str_failed_trunc2_len
    call    do_write_err
    pop     rbp
    mov     ebp, 1
    pop     r15
    pop     r14
    pop     r13
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
    db "Usage: truncate OPTION... FILE...", 10
    db "Shrink or extend the size of each FILE to the specified size.", 10, 10
    db "A FILE argument that does not exist is created.", 10, 10
    db "If a FILE is larger than the specified size, the extra data is lost.", 10
    db "If a FILE is shorter, it is extended, and the sparse extended part (hole)", 10
    db "reads as zero bytes.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -c, --no-create        do not create any files", 10
    db "  -o, --io-blocks        treat SIZE as number of IO blocks instead of bytes", 10
    db "  -r, --reference=RFILE  base size on RFILE", 10
    db "  -s, --size=SIZE        set or adjust the file size by SIZE bytes", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "SIZE may also be prefixed by one of the following modifying characters:", 10
    db "'+' extend by, '-' reduce by, '<' at most, '>' at least,", 10
    db "'/' round down to multiple of, '%' round up to multiple of.", 10, 10
    db "SIZE may have a multiplier suffix:", 10
    db "KB 1000, K 1024, MB 1000*1000, M 1024*1024, and so on for G, T, P, E, Z, Y,", 10
    db "R, Q.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/truncate>", 10
    db "or available locally via: info '(coreutils) truncate invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "truncate (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Padraig Brady.", 10
str_version_len equ $ - str_version

str_prefix:         db "truncate: "
str_prefix_len      equ $ - str_prefix
str_unrecog:        db "unrecognized option '"
str_unrecog_len     equ $ - str_unrecog
str_invalid:        db "invalid option -- '"
str_invalid_len     equ $ - str_invalid
str_missing:        db "missing file operand", 10
str_missing_len     equ $ - str_missing
str_sq_nl:          db "'", 10
str_try:            db "Try 'truncate --help' for more information.", 10
str_try_len         equ $ - str_try
str_opt_req_s:      db "option requires an argument -- 's'", 10
str_opt_req_s_len   equ $ - str_opt_req_s
str_opt_req_r:      db "option requires an argument -- 'r'", 10
str_opt_req_r_len   equ $ - str_opt_req_r
str_must_specify:   db "you must specify either '--size' or '--reference'", 10
str_must_specify_len equ $ - str_must_specify
str_invalid_num:    db "invalid number", 10
str_invalid_num_len equ $ - str_invalid_num
str_cannot_open1:   db "cannot open '"
str_cannot_open1_len equ $ - str_cannot_open1
str_cannot_open2:   db "' for writing: No such file or directory", 10
str_cannot_open2_len equ $ - str_cannot_open2
str_cannot_stat:    db "cannot stat '"
str_cannot_stat_len equ $ - str_cannot_stat
str_no_such:        db "': No such file or directory", 10
str_no_such_len     equ $ - str_no_such
str_failed_trunc1:  db "failed to truncate '"
str_failed_trunc1_len equ $ - str_failed_trunc1
str_failed_trunc2:  db "' to specified size", 10
str_failed_trunc2_len equ $ - str_failed_trunc2
; @@DATA_END@@

str_help_flag:      db "--help", 0
str_version_flag:   db "--version", 0
str_no_create_flag: db "--no-create", 0
str_size_prefix:    db "--size=", 0
str_ref_prefix:     db "--reference=", 0

file_size equ $ - $$
