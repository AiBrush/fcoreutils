%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write
extern asm_write_err
extern asm_exit
extern asm_strlen
extern asm_strcmp

global _start

; ============================================================
; Data Section
; ============================================================
section .data

str_help:
    db "Usage: sleep NUMBER[SUFFIX]...", 10
    db "  or:  sleep OPTION", 10
    db "Pause for NUMBER seconds.  SUFFIX may be 's' for seconds (the default),", 10
    db "'m' for minutes, 'h' for hours or 'd' for days.  NUMBER need not be an", 10
    db "integer.  Given two or more arguments, pause for the amount of time", 10
    db "specified by the sum of their values.", 10
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
    db "sleep: invalid time interval '", 0
str_invalid_pre_len equ $ - str_invalid_pre - 1  ; minus null

str_invalid_post:
    db "'", 10, 0
str_invalid_post_len equ $ - str_invalid_post - 1

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

; Multiplier constants (stored as seconds * 1_000_000_000 for nanosecond precision)
; Actually we'll compute in seconds+nanoseconds
; Suffix multipliers in seconds
mult_s  dq  1
mult_m  dq  60
mult_h  dq  3600
mult_d  dq  86400

; ============================================================
; BSS Section
; ============================================================
section .bss
    timespec_sec  resq 1      ; tv_sec for nanosleep
    timespec_nsec resq 1      ; tv_nsec for nanosleep
    timespec_rem  resq 2      ; remainder timespec

; ============================================================
; Text Section
; ============================================================
section .text

_start:
    ; Get argc and argv
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv

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
    call    asm_strcmp
    pop     r8
    pop     rcx
    test    eax, eax
    jz      .show_help

    ; Check for "--version"
    mov     rdi, [r15 + rcx*8]
    push    rcx
    push    r8
    mov     rsi, str_opt_version
    call    asm_strcmp
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
    ; Starts with '-', check second char
    cmp     byte [rdi + 1], '-'
    je      .check_double_dash
    ; Single dash: -x → "invalid option -- 'x'"
    cmp     byte [rdi + 1], 0
    je      .not_flag           ; bare "-" is not a flag, treat as invalid time
    jmp     .invalid_option

.check_double_dash:
    ; Starts with '--', check if it's just '--' (end of options)
    cmp     byte [rdi + 2], 0
    je      .end_of_options
    ; '--something' → "unrecognized option"
    jmp     .unrecognized_option

.end_of_options:
    ; '--' means end of options, remaining args are operands
    mov     r8d, 1
    inc     rbx
    jmp     .arg_loop

.not_flag:
    call    parse_time_arg      ; returns: rax=seconds, rdx=nanoseconds, rcx=0 ok / 1 error / 2 infinity
    cmp     rcx, 1
    je      .invalid_arg
    cmp     rcx, 2
    je      .sleep_infinity

    ; Accumulate
    add     r12, rax            ; total_sec += sec
    add     r13, rdx            ; total_nsec += nsec
    ; Carry from nanoseconds to seconds
    cmp     r13, 1000000000
    jb      .no_carry
    sub     r13, 1000000000
    inc     r12
.no_carry:
    inc     rbx
    jmp     .arg_loop

.do_sleep:
    ; Check if total is zero
    test    r12, r12
    jnz     .call_nanosleep
    test    r13, r13
    jz      .exit_ok            ; sleep 0 = exit immediately

.call_nanosleep:
    mov     [timespec_sec], r12
    mov     [timespec_nsec], r13
.nanosleep_retry:
    mov     rax, SYS_NANOSLEEP
    lea     rdi, [rel timespec_sec]
    lea     rsi, [rel timespec_rem]
    syscall
    ; If interrupted by signal (EINTR = -4), retry with remaining time
    cmp     rax, -4
    jne     .exit_ok
    ; Copy remainder to request
    mov     rax, [timespec_rem]
    mov     [timespec_sec], rax
    mov     rax, [timespec_rem + 8]
    mov     [timespec_nsec], rax
    jmp     .nanosleep_retry

.exit_ok:
    xor     rdi, rdi
    call    asm_exit

.sleep_infinity:
    ; Sleep in a loop of 86400 seconds (1 day)
    mov     qword [timespec_sec], 86400
    mov     qword [timespec_nsec], 0
.inf_loop:
    mov     rax, SYS_NANOSLEEP
    lea     rdi, [rel timespec_sec]
    lea     rsi, [rel timespec_rem]
    syscall
    ; Reset to 86400 seconds (in case rem was used)
    mov     qword [timespec_sec], 86400
    mov     qword [timespec_nsec], 0
    jmp     .inf_loop

.show_help:
    mov     rdi, STDOUT
    mov     rsi, str_help
    mov     rdx, str_help_len
    call    asm_write
    xor     rdi, rdi
    call    asm_exit

.show_version:
    mov     rdi, STDOUT
    mov     rsi, str_version
    mov     rdx, str_version_len
    call    asm_write
    xor     rdi, rdi
    call    asm_exit

.missing_operand:
    mov     rsi, str_missing
    mov     rdx, str_missing_len
    call    asm_write_err
    mov     rsi, str_try
    mov     rdx, str_try_len
    call    asm_write_err
    mov     rdi, 1
    call    asm_exit

.invalid_arg:
    ; Print: sleep: invalid time interval 'ARG'\n
    ; rdi still has the arg pointer from parse, but we need to get it again
    mov     rdi, [r15 + rbx*8]  ; argv[i]
    push    rdi                 ; save arg pointer

    ; "sleep: invalid time interval '"
    mov     rsi, str_invalid_pre
    mov     rdx, str_invalid_pre_len
    call    asm_write_err

    ; The argument itself
    pop     rdi                 ; restore arg pointer
    push    rdi
    call    asm_strlen          ; rax = length
    pop     rsi                 ; rsi = arg pointer
    mov     rdx, rax
    call    asm_write_err

    ; "'\n"
    mov     rsi, str_invalid_post
    mov     rdx, str_invalid_post_len
    call    asm_write_err

    ; "Try 'sleep --help' for more information.\n"
    mov     rsi, str_try
    mov     rdx, str_try_len
    call    asm_write_err

    mov     rdi, 1
    call    asm_exit

.unrecognized_option:
    ; Print: sleep: unrecognized option 'ARG'\nTry...\n
    mov     rdi, [r15 + rbx*8]  ; argv[i]
    push    rdi

    mov     rsi, str_unrec_opt_pre
    mov     rdx, str_unrec_opt_pre_len
    call    asm_write_err

    pop     rdi
    push    rdi
    call    asm_strlen
    pop     rsi
    mov     rdx, rax
    call    asm_write_err

    mov     rsi, str_invalid_post
    mov     rdx, str_invalid_post_len
    call    asm_write_err

    mov     rsi, str_try
    mov     rdx, str_try_len
    call    asm_write_err

    mov     rdi, 1
    call    asm_exit

.invalid_option:
    ; Print: sleep: invalid option -- 'X'\nTry...\n
    ; where X is the character after '-'
    mov     rdi, [r15 + rbx*8]  ; argv[i]

    mov     rsi, str_inv_opt_pre
    mov     rdx, str_inv_opt_pre_len
    call    asm_write_err

    ; Print the character after '-'
    mov     rdi, [r15 + rbx*8]
    lea     rsi, [rdi + 1]      ; point to char after '-'
    mov     rdx, 1
    call    asm_write_err

    mov     rsi, str_invalid_post
    mov     rdx, str_invalid_post_len
    call    asm_write_err

    mov     rsi, str_try
    mov     rdx, str_try_len
    call    asm_write_err

    mov     rdi, 1
    call    asm_exit

; ============================================================
; strcasecmp_local - Case-insensitive string comparison
; Input: rdi=s1, rsi=s2 (s2 must be lowercase)
; Output: eax: 0=equal, nonzero=different
; ============================================================
strcasecmp_local:
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
; parse_time_arg - Parse a time argument like "1.5s" or "3m"
;
; Input:  rdi = pointer to null-terminated string
; Output: rax = integer seconds
;         rdx = nanoseconds (0-999999999)
;         rcx = status: 0=ok, 1=error, 2=infinity
;
; Handles: integer, float, suffixes s/m/h/d, "infinity", "inf"
; ============================================================
parse_time_arg:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r15, rdi            ; save string pointer

    ; Check for "infinity" (case-insensitive)
    mov     rsi, str_infinity
    call    strcasecmp_local
    test    eax, eax
    jz      .pt_infinity

    ; Check for "inf" (case-insensitive)
    mov     rdi, r15
    mov     rsi, str_inf
    call    strcasecmp_local
    test    eax, eax
    jz      .pt_infinity

    ; Parse the number
    mov     rdi, r15
    xor     r12, r12            ; integer_part = 0
    xor     r13, r13            ; frac_part (nanoseconds) = 0
    xor     rbx, rbx            ; index into string
    xor     rbp, rbp            ; has_digits = 0

    ; Check for leading sign (only + is valid for sleep, - is invalid)
    movzx   eax, byte [rdi]
    cmp     al, '-'
    je      .pt_error           ; negative = error
    cmp     al, '+'
    jne     .pt_parse_int
    inc     rbx                 ; skip '+'

.pt_parse_int:
    ; Parse integer part
    movzx   eax, byte [rdi + rbx]
    cmp     al, '0'
    jb      .pt_check_dot
    cmp     al, '9'
    ja      .pt_check_dot
    sub     al, '0'
    ; r12 = r12 * 10 + digit
    imul    r12, 10
    movzx   ecx, al
    add     r12, rcx
    inc     rbp                 ; has_digits = 1
    inc     rbx
    jmp     .pt_parse_int

.pt_check_dot:
    cmp     al, '.'
    jne     .pt_suffix

    inc     rbx                 ; skip '.'

    ; Parse fractional part - compute nanoseconds
    ; We parse up to 9 decimal digits, multiply to get nanoseconds
    mov     r14, 100000000      ; multiplier for first frac digit
    xor     r13, r13            ; frac_nsec = 0

.pt_parse_frac:
    movzx   eax, byte [rdi + rbx]
    cmp     al, '0'
    jb      .pt_suffix
    cmp     al, '9'
    ja      .pt_suffix
    sub     al, '0'
    movzx   ecx, al
    imul    rcx, r14            ; digit * place_value
    add     r13, rcx
    ; Divide multiplier by 10 for next digit
    mov     rax, r14
    xor     edx, edx
    mov     rcx, 10
    div     rcx
    mov     r14, rax
    inc     rbp                 ; has_digits
    inc     rbx
    ; Only parse up to 9 decimal digits
    test    r14, r14
    jz      .pt_skip_frac
    jmp     .pt_parse_frac

.pt_skip_frac:
    ; Skip any remaining fractional digits
    movzx   eax, byte [rdi + rbx]
    cmp     al, '0'
    jb      .pt_suffix
    cmp     al, '9'
    ja      .pt_suffix
    inc     rbx
    jmp     .pt_skip_frac

.pt_suffix:
    ; Must have at least one digit
    test    rbp, rbp
    jz      .pt_error

    ; Check suffix character
    movzx   eax, byte [rdi + rbx]
    test    al, al
    jz      .pt_apply_mult_s    ; no suffix = seconds

    cmp     al, 's'
    je      .pt_suffix_next_s
    cmp     al, 'm'
    je      .pt_suffix_next_m
    cmp     al, 'h'
    je      .pt_suffix_next_h
    cmp     al, 'd'
    je      .pt_suffix_next_d
    jmp     .pt_error           ; unknown suffix

.pt_suffix_next_s:
    inc     rbx
    cmp     byte [rdi + rbx], 0
    jne     .pt_error
    jmp     .pt_apply_mult_s

.pt_suffix_next_m:
    inc     rbx
    cmp     byte [rdi + rbx], 0
    jne     .pt_error
    jmp     .pt_apply_mult_m

.pt_suffix_next_h:
    inc     rbx
    cmp     byte [rdi + rbx], 0
    jne     .pt_error
    jmp     .pt_apply_mult_h

.pt_suffix_next_d:
    inc     rbx
    cmp     byte [rdi + rbx], 0
    jne     .pt_error
    jmp     .pt_apply_mult_d

.pt_apply_mult_s:
    ; Multiplier = 1 (seconds, no change needed)
    mov     rax, r12            ; seconds
    mov     rdx, r13            ; nanoseconds
    xor     rcx, rcx            ; status = ok
    jmp     .pt_done

.pt_apply_mult_m:
    ; Multiplier = 60
    ; sec = int_part * 60 + (nsec * 60) / 1e9
    ; nsec = (nsec * 60) % 1e9
    mov     rax, r13
    imul    rax, 60             ; nsec * 60
    xor     edx, edx
    mov     rcx, 1000000000
    div     rcx                 ; rax = extra_sec, rdx = remaining nsec
    mov     r13, rdx            ; updated nsec
    imul    r12, 60             ; int_part * 60
    add     r12, rax            ; add extra seconds from fractional
    mov     rax, r12
    mov     rdx, r13
    xor     rcx, rcx
    jmp     .pt_done

.pt_apply_mult_h:
    ; Multiplier = 3600
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
    xor     rcx, rcx
    jmp     .pt_done

.pt_apply_mult_d:
    ; Multiplier = 86400
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
    xor     rcx, rcx
    jmp     .pt_done

.pt_infinity:
    xor     rax, rax
    xor     rdx, rdx
    mov     rcx, 2              ; status = infinity
    jmp     .pt_done

.pt_error:
    xor     rax, rax
    xor     rdx, rdx
    mov     rcx, 1              ; status = error
    jmp     .pt_done

.pt_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
