; ============================================================
; fsleep_unified.asm — AUTO-GENERATED unified file
; sleep (GNU coreutils compatible) — x86_64 Linux
; Build: nasm -f bin fsleep_unified.asm -o fsleep_release
; ============================================================
BITS 64
ORG 0x400000

; === ELF Header (64 bytes) ===
ehdr:
    db 0x7f, 'E','L','F'       ; magic
    db 2                        ; 64-bit
    db 1                        ; little endian
    db 1                        ; ELF version
    db 0                        ; OS/ABI: System V
    dq 0                        ; padding
    dw 2                        ; ET_EXEC
    dw 0x3e                     ; x86_64
    dd 1                        ; ELF version
    dq _start                   ; entry point
    dq phdr - $$                ; program header offset
    dq 0                        ; section header offset (none)
    dd 0                        ; flags
    dw ehdr_size                ; ELF header size
    dw phdr_size                ; program header entry size
    dw 2                        ; 2 program headers
    dw 64                       ; section header entry size
    dw 0                        ; section header count
    dw 0                        ; section name index
ehdr_size equ $ - ehdr

; === Program Header 1: PT_LOAD (code + data) ===
phdr:
    dd 1                        ; PT_LOAD
    dd 5                        ; PF_R | PF_X
    dq 0                        ; offset in file
    dq $$                       ; virtual address
    dq $$                       ; physical address
    dq file_size                ; file size
    dq file_size                ; memory size (no BSS needed, using stack)
    dq 0x200000                 ; alignment
phdr_size equ $ - phdr

; === Program Header 2: PT_GNU_STACK (NX stack) ===
    dd 0x6474e551               ; PT_GNU_STACK
    dd 6                        ; PF_R | PF_W (no PF_X)
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 16                       ; alignment

; ============================================================
; Syscall numbers
; ============================================================
%define SYS_WRITE       1
%define SYS_EXIT       60
%define SYS_NANOSLEEP  35
%define STDOUT          1
%define STDERR          2

; ============================================================
; Code Section
; ============================================================

_start:
    ; Reserve 32 bytes on stack for timespec structs
    ; [rsp]    = tv_sec  (request)
    ; [rsp+8]  = tv_nsec (request)
    ; [rsp+16] = tv_sec  (remainder)
    ; [rsp+24] = tv_nsec (remainder)
    sub     rsp, 32

    ; Get argc and argv
    mov     r14, [rsp + 32]     ; argc (past our 32-byte alloc)
    lea     r15, [rsp + 40]     ; argv

    ; Check for no arguments (argc == 1, only program name)
    cmp     r14, 1
    jle     .missing_operand

    ; ============================================================
    ; PASS 1: Scan ALL argv for --help / --version
    ; GNU sleep uses parse_gnu_standard_options_only() which checks
    ; every argv entry for --help/--version, respecting --.
    ; ============================================================
    mov     rcx, 1              ; start at argv[1]
    xor     r8d, r8d            ; r8 = 0: not past "--" yet

.scan_loop:
    cmp     rcx, r14
    jge     .scan_done

    mov     rdi, [r15 + rcx*8]  ; argv[i]

    ; If past "--", skip option checking
    test    r8d, r8d
    jnz     .scan_next

    ; Check if starts with '-'
    cmp     byte [rdi], '-'
    jne     .scan_next

    ; Check for "--"
    cmp     byte [rdi + 1], '-'
    jne     .scan_next

    ; Check for exactly "--"
    cmp     byte [rdi + 2], 0
    je      .scan_set_past

    ; Check for "--help"
    push    rcx
    push    r8
    mov     rsi, str_opt_help
    call    _strcmp
    pop     r8
    pop     rcx
    test    eax, eax
    jz      .show_help

    ; Check for "--version"
    mov     rdi, [r15 + rcx*8]
    push    rcx
    push    r8
    mov     rsi, str_opt_version
    call    _strcmp
    pop     r8
    pop     rcx
    test    eax, eax
    jz      .show_version

    jmp     .scan_next

.scan_set_past:
    mov     r8d, 1              ; past "--"
.scan_next:
    inc     rcx
    jmp     .scan_loop

.scan_done:
    ; ============================================================
    ; PASS 2: Parse arguments, accumulate time
    ; r12 = total seconds (integer part)
    ; r13 = total nanoseconds (fractional part, 0-999999999)
    ; rbx = arg index
    ; rbp = argc
    ; r8  = "past options" flag (0 = checking options, 1 = past --)
    ; ============================================================
    xor     r12, r12            ; total_sec = 0
    xor     r13, r13            ; total_nsec = 0
    mov     rbx, 1              ; arg index (start at 1, skip argv[0])
    mov     rbp, r14            ; argc
    xor     r8d, r8d            ; not past "--" yet

.arg_loop:
    cmp     rbx, rbp
    jge     .do_sleep           ; processed all args

    mov     rdi, [r15 + rbx*8]  ; argv[i]

    ; If past "--", skip option checking — go straight to parsing
    test    r8d, r8d
    jnz     .not_flag

    ; Check for flag-like arguments starting with '-'
    cmp     byte [rdi], '-'
    jne     .not_flag
    cmp     byte [rdi + 1], '-'
    je      .check_double_dash
    cmp     byte [rdi + 1], 0
    je      .not_flag
    jmp     .invalid_option

.check_double_dash:
    cmp     byte [rdi + 2], 0
    je      .end_of_options
    jmp     .unrecognized_option

.end_of_options:
    ; Set "past options" flag; this -- itself is skipped (not parsed as time)
    mov     r8d, 1
    inc     rbx
    jmp     .arg_loop

.not_flag:
    call    _parse_time         ; returns: rax=seconds, rdx=nanoseconds, rcx=0 ok / 1 error / 2 infinity
    cmp     rcx, 1
    je      .invalid_arg
    cmp     rcx, 2
    je      .sleep_infinity

    ; Accumulate
    add     r12, rax
    add     r13, rdx
    cmp     r13, 1000000000
    jb      .no_carry
    sub     r13, 1000000000
    inc     r12
.no_carry:
    inc     rbx
    jmp     .arg_loop

.do_sleep:
    test    r12, r12
    jnz     .call_nanosleep
    test    r13, r13
    jz      .exit_ok

.call_nanosleep:
    mov     [rsp], r12
    mov     [rsp + 8], r13
.nanosleep_retry:
    mov     rax, SYS_NANOSLEEP
    mov     rdi, rsp
    lea     rsi, [rsp + 16]
    syscall
    cmp     rax, -4             ; -EINTR?
    jne     .exit_ok
    mov     rax, [rsp + 16]
    mov     [rsp], rax
    mov     rax, [rsp + 24]
    mov     [rsp + 8], rax
    jmp     .nanosleep_retry

.exit_ok:
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.sleep_infinity:
    mov     qword [rsp], 86400
    mov     qword [rsp + 8], 0
.inf_loop:
    mov     rax, SYS_NANOSLEEP
    mov     rdi, rsp
    lea     rsi, [rsp + 16]
    syscall
    mov     qword [rsp], 86400
    mov     qword [rsp + 8], 0
    jmp     .inf_loop

.show_help:
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    _write
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.show_version:
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    _write
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.missing_operand:
    mov     edi, STDERR
    mov     rsi, str_missing
    mov     edx, str_missing_len
    call    _write
    mov     edi, STDERR
    mov     rsi, str_try
    mov     edx, str_try_len
    call    _write
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.invalid_arg:
    mov     rdi, [r15 + rbx*8]
    push    rdi
    mov     edi, STDERR
    mov     rsi, str_invalid_pre
    mov     edx, str_invalid_pre_len
    call    _write
    pop     rdi
    push    rdi
    call    _strlen
    pop     rsi
    mov     rdx, rax
    mov     edi, STDERR
    call    _write
    mov     edi, STDERR
    mov     rsi, str_invalid_post_unicode
    mov     edx, str_invalid_post_unicode_len
    call    _write
    mov     edi, STDERR
    mov     rsi, str_try
    mov     edx, str_try_len
    call    _write
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.unrecognized_option:
    mov     rdi, [r15 + rbx*8]
    push    rdi
    mov     edi, STDERR
    mov     rsi, str_unrec_opt_pre
    mov     edx, str_unrec_opt_pre_len
    call    _write
    pop     rdi
    push    rdi
    call    _strlen
    pop     rsi
    mov     rdx, rax
    mov     edi, STDERR
    call    _write
    mov     edi, STDERR
    mov     rsi, str_invalid_post
    mov     edx, str_invalid_post_len
    call    _write
    mov     edi, STDERR
    mov     rsi, str_try
    mov     edx, str_try_len
    call    _write
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.invalid_option:
    mov     rdi, [r15 + rbx*8]
    mov     edi, STDERR
    mov     rsi, str_inv_opt_pre
    mov     edx, str_inv_opt_pre_len
    call    _write
    mov     rdi, [r15 + rbx*8]
    lea     rsi, [rdi + 1]
    mov     edx, 1
    mov     edi, STDERR
    call    _write
    mov     edi, STDERR
    mov     rsi, str_invalid_post
    mov     edx, str_invalid_post_len
    call    _write
    mov     edi, STDERR
    mov     rsi, str_try
    mov     edx, str_try_len
    call    _write
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

; ============================================================
; _write(edi=fd, rsi=buf, edx=len) — write with EINTR retry
; ============================================================
_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      _write
    ret

; ============================================================
; _strlen(rdi=str) -> rax=length
; ============================================================
_strlen:
    xor     eax, eax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

; ============================================================
; _strcmp(rdi=s1, rsi=s2) -> eax: 0=equal
; ============================================================
_strcmp:
.loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .diff
    test    al, al
    jz      .equal
    inc     rdi
    inc     rsi
    jmp     .loop
.equal:
    xor     eax, eax
    ret
.diff:
    sub     eax, ecx
    ret

; ============================================================
; _strcasecmp(rdi=s1, rsi=s2) -> eax: 0=equal (case-insensitive)
; Compares s1 against s2 case-insensitively (s2 must be lowercase)
; ============================================================
_strcasecmp:
.loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    ; Convert al to lowercase if A-Z
    cmp     al, 'A'
    jb      .no_lower
    cmp     al, 'Z'
    ja      .no_lower
    add     al, 32              ; 'A' -> 'a'
.no_lower:
    cmp     al, cl
    jne     .diff
    test    al, al
    jz      .equal
    inc     rdi
    inc     rsi
    jmp     .loop
.equal:
    xor     eax, eax
    ret
.diff:
    sub     eax, ecx
    ret

; ============================================================
; _parse_time(rdi=str) -> rax=sec, rdx=nsec, rcx=status
; status: 0=ok, 1=error, 2=infinity
; ============================================================
_parse_time:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r15, rdi

    ; Check for "infinity" (case-insensitive)
    mov     rsi, str_infinity
    call    _strcasecmp
    test    eax, eax
    jz      .pt_infinity

    mov     rdi, r15
    mov     rsi, str_inf
    call    _strcasecmp
    test    eax, eax
    jz      .pt_infinity

    mov     rdi, r15
    xor     r12, r12            ; integer_part = 0
    xor     r13, r13            ; frac_part (nanoseconds) = 0
    xor     ebx, ebx            ; index
    xor     ebp, ebp            ; has_digits

    movzx   eax, byte [rdi]
    cmp     al, '-'
    je      .pt_error
    cmp     al, '+'
    jne     .pt_parse_int
    inc     ebx

.pt_parse_int:
    movzx   eax, byte [rdi + rbx]
    cmp     al, '0'
    jb      .pt_check_dot
    cmp     al, '9'
    ja      .pt_check_dot
    sub     al, '0'
    imul    r12, 10
    movzx   ecx, al
    add     r12, rcx
    inc     ebp
    inc     ebx
    jmp     .pt_parse_int

.pt_check_dot:
    cmp     al, '.'
    jne     .pt_suffix
    inc     ebx
    mov     r14, 100000000
    xor     r13, r13

.pt_parse_frac:
    movzx   eax, byte [rdi + rbx]
    cmp     al, '0'
    jb      .pt_suffix
    cmp     al, '9'
    ja      .pt_suffix
    sub     al, '0'
    movzx   ecx, al
    imul    rcx, r14
    add     r13, rcx
    mov     rax, r14
    xor     edx, edx
    mov     rcx, 10
    div     rcx
    mov     r14, rax
    inc     ebp
    inc     ebx
    test    r14, r14
    jz      .pt_skip_frac
    jmp     .pt_parse_frac

.pt_skip_frac:
    movzx   eax, byte [rdi + rbx]
    cmp     al, '0'
    jb      .pt_suffix
    cmp     al, '9'
    ja      .pt_suffix
    inc     ebx
    jmp     .pt_skip_frac

.pt_suffix:
    test    ebp, ebp
    jz      .pt_error

    movzx   eax, byte [rdi + rbx]
    test    al, al
    jz      .pt_mult_s

    cmp     al, 's'
    je      .pt_sfx_s
    cmp     al, 'm'
    je      .pt_sfx_m
    cmp     al, 'h'
    je      .pt_sfx_h
    cmp     al, 'd'
    je      .pt_sfx_d
    jmp     .pt_error

.pt_sfx_s:
    inc     ebx
    cmp     byte [rdi + rbx], 0
    jne     .pt_error
    jmp     .pt_mult_s
.pt_sfx_m:
    inc     ebx
    cmp     byte [rdi + rbx], 0
    jne     .pt_error
    jmp     .pt_mult_m
.pt_sfx_h:
    inc     ebx
    cmp     byte [rdi + rbx], 0
    jne     .pt_error
    jmp     .pt_mult_h
.pt_sfx_d:
    inc     ebx
    cmp     byte [rdi + rbx], 0
    jne     .pt_error
    jmp     .pt_mult_d

.pt_mult_s:
    mov     rax, r12
    mov     rdx, r13
    xor     ecx, ecx
    jmp     .pt_done
.pt_mult_m:
    mov     rax, r13
    imul    rax, 60
    xor     edx, edx
    mov     rcx, 1000000000
    div     rcx
    mov     r13, rdx
    imul    r12, 60
    add     r12, rax
    mov     rax, r12
    mov     rdx, r13
    xor     ecx, ecx
    jmp     .pt_done
.pt_mult_h:
    mov     rax, r13
    imul    rax, 3600
    xor     edx, edx
    mov     rcx, 1000000000
    div     rcx
    mov     r13, rdx
    imul    r12, 3600
    add     r12, rax
    mov     rax, r12
    mov     rdx, r13
    xor     ecx, ecx
    jmp     .pt_done
.pt_mult_d:
    mov     rax, r13
    imul    rax, 86400
    xor     edx, edx
    mov     rcx, 1000000000
    div     rcx
    mov     r13, rdx
    imul    r12, 86400
    add     r12, rax
    mov     rax, r12
    mov     rdx, r13
    xor     ecx, ecx
    jmp     .pt_done

.pt_infinity:
    xor     eax, eax
    xor     edx, edx
    mov     ecx, 2
    jmp     .pt_done

.pt_error:
    xor     eax, eax
    xor     edx, edx
    mov     ecx, 1

.pt_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ============================================================
; Data Section
; ============================================================

str_help:
    db "Usage: sleep NUMBER[SUFFIX]...", 10
    db "  or:  sleep OPTION", 10
    db "Pause for NUMBER seconds, where NUMBER is an integer or floating-point.", 10
    db "SUFFIX may be 's','m','h', or 'd', for seconds, minutes, hours, days.", 10
    db "With multiple arguments, pause for the sum of their values.", 10
    db 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/sleep>", 10
    db "or available locally via: info '(coreutils) sleep invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "sleep (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by Jim Meyering and Paul Eggert.", 10
str_version_len equ $ - str_version

str_missing:
    db "sleep: missing operand", 10
str_missing_len equ $ - str_missing

str_try:
    db "Try 'sleep --help' for more information.", 10
str_try_len equ $ - str_try

str_invalid_pre:
    db "sleep: invalid time interval ", 0xE2, 0x80, 0x98, 0
str_invalid_pre_len equ $ - str_invalid_pre - 1

str_invalid_post:
    db "'", 10, 0
str_invalid_post_len equ $ - str_invalid_post - 1

str_invalid_post_unicode:
    db 0xE2, 0x80, 0x99, 10, 0
str_invalid_post_unicode_len equ $ - str_invalid_post_unicode - 1

str_unrec_opt_pre:
    db "sleep: unrecognized option '", 0
str_unrec_opt_pre_len equ $ - str_unrec_opt_pre - 1

str_inv_opt_pre:
    db "sleep: invalid option -- '", 0
str_inv_opt_pre_len equ $ - str_inv_opt_pre - 1

str_opt_help:
    db "--help", 0

str_opt_version:
    db "--version", 0

str_infinity:
    db "infinity", 0

str_inf:
    db "inf", 0

; ============================================================
file_size equ $ - $$
