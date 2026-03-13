; fkill.asm — GNU-compatible kill command
;
; kill PID...          send SIGTERM to processes
; kill -s SIGNAL PID.. send named signal
; kill -SIGNAL PID...  send signal (e.g., kill -9, kill -HUP)
; kill -l              list all signals
; kill -l SIGNAL       print signal name for number
;
; Syscalls: kill(62), getpid(39)

%include "include/linux.inc"

extern asm_write
extern asm_exit
extern asm_strlen
extern asm_itoa

global _start

section .bss
    num_buf: resb 32

section .text

_start:
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Need at least one argument
    cmp     r14, 1
    jle     .missing_operand

    ; Start at argv[1]
    mov     r12, 1              ; arg index
    mov     r13, 15             ; default signal = SIGTERM

    mov     rsi, [r15 + r12*8]  ; argv[1]

    ; Check for "--help"
    cmp     dword [rsi], 0x65682D2D     ; "--he"
    jne     .chk_version
    cmp     word [rsi+4], 0x706C        ; "lp"
    jne     .chk_version
    cmp     byte [rsi+6], 0
    jne     .chk_version
    jmp     .do_help

.chk_version:
    cmp     dword [rsi], 0x65762D2D     ; "--ve"
    jne     .chk_list
    cmp     dword [rsi+4], 0x6F697372   ; "rsio"
    jne     .chk_list
    cmp     word [rsi+8], 0x006E        ; "n\0"
    jne     .chk_list
    jmp     .do_version

.chk_list:
    ; Check for -l
    cmp     byte [rsi], '-'
    jne     .parse_pids
    cmp     byte [rsi+1], 'l'
    jne     .chk_signal_opt
    cmp     byte [rsi+2], 0
    jne     .chk_signal_opt

    ; -l mode
    inc     r12
    cmp     r12, r14
    jge     .list_all_signals

    ; -l SIGNAL — translate signal number to name
    mov     rsi, [r15 + r12*8]
    call    _atoi
    test    rdx, rdx
    jnz     .invalid_signal

    ; Mask off high bit (128+sig -> sig for exit status)
    cmp     rax, 128
    jl      .no_mask
    sub     rax, 128
.no_mask:
    ; Look up signal name
    cmp     rax, 0
    je      .invalid_signal_num
    cmp     rax, 31
    ja      .invalid_signal_num

    ; Index into signal name table
    dec     rax
    lea     rsi, [rel sig_name_table]
    shl     rax, 4              ; each entry is 16 bytes
    add     rsi, rax
    mov     rdi, rsi
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, rdi
    mov     edi, STDOUT
    call    asm_write
    mov     edi, STDOUT
    lea     rsi, [rel newline]
    mov     edx, 1
    call    asm_write
    xor     edi, edi
    call    asm_exit

.list_all_signals:
    ; Print all signals: " 1) HUP\n 2) INT\n ..."
    mov     r12, 1              ; signal number
.list_loop:
    cmp     r12, 31
    ja      .list_done

    ; Print number
    mov     rdi, r12
    lea     rsi, [rel num_buf]
    call    asm_itoa
    mov     rdx, rax
    lea     rsi, [rel num_buf]
    mov     edi, STDOUT
    call    asm_write

    ; Print ") "
    mov     edi, STDOUT
    lea     rsi, [rel str_paren_space]
    mov     edx, 2
    call    asm_write

    ; Print signal name
    mov     rax, r12
    dec     rax
    lea     rsi, [rel sig_name_table]
    shl     rax, 4
    add     rsi, rax
    mov     rdi, rsi
    push    rdi
    call    asm_strlen
    pop     rsi
    mov     rdx, rax
    mov     edi, STDOUT
    call    asm_write

    ; Print newline
    mov     edi, STDOUT
    lea     rsi, [rel newline]
    mov     edx, 1
    call    asm_write

    inc     r12
    jmp     .list_loop

.list_done:
    xor     edi, edi
    call    asm_exit

.chk_signal_opt:
    ; Check for -s SIGNAL
    cmp     byte [rsi], '-'
    jne     .parse_pids
    cmp     byte [rsi+1], 's'
    jne     .chk_dash_signal
    cmp     byte [rsi+2], 0
    jne     .chk_dash_signal

    ; -s SIGNAL
    inc     r12
    cmp     r12, r14
    jge     .missing_operand
    mov     rsi, [r15 + r12*8]
    call    _parse_signal
    test    rdx, rdx
    jnz     .invalid_signal
    mov     r13, rax            ; signal number
    inc     r12
    jmp     .parse_pids

.chk_dash_signal:
    ; Check for -SIGNAL (e.g., -9, -HUP, -TERM)
    cmp     byte [rsi], '-'
    jne     .parse_pids
    lea     rdi, [rsi + 1]
    ; Is it a number?
    cmp     byte [rdi], '0'
    jb      .try_sig_name
    cmp     byte [rdi], '9'
    ja      .try_sig_name

    ; It's -NUMBER
    mov     rsi, rdi
    call    _atoi
    test    rdx, rdx
    jnz     .invalid_signal
    mov     r13, rax
    inc     r12
    jmp     .parse_pids

.try_sig_name:
    ; It's -NAME (e.g., -HUP, -TERM)
    mov     rsi, rdi
    call    _lookup_signal_name
    test    rdx, rdx
    jnz     .invalid_signal
    mov     r13, rax
    inc     r12
    jmp     .parse_pids

.parse_pids:
    ; Need at least one PID
    cmp     r12, r14
    jge     .missing_operand

    xor     ebp, ebp            ; exit_status = 0

.pid_loop:
    cmp     r12, r14
    jge     .exit_with_status

    mov     rsi, [r15 + r12*8]

    ; Parse PID (might be negative for process group)
    xor     r8d, r8d            ; negative flag
    cmp     byte [rsi], '-'
    jne     .parse_pid_digits
    mov     r8d, 1
    inc     rsi

.parse_pid_digits:
    call    _atoi
    test    rdx, rdx
    jnz     .invalid_pid

    ; Apply sign
    test    r8d, r8d
    jz      .do_kill
    neg     rax

.do_kill:
    ; kill(pid, sig)
    mov     rdi, rax            ; pid
    mov     rsi, r13            ; signal
    mov     rax, SYS_KILL
    syscall

    test    rax, rax
    jns     .kill_ok

    ; Error
    mov     ebp, 1
    ; Print error message
    push    r12
    mov     edi, STDERR
    lea     rsi, [rel str_err_prefix]
    mov     edx, str_err_prefix_len
    call    asm_write

    ; Print "(<PID>)"
    lea     rsi, [rel str_paren_open]
    mov     edx, 1
    mov     edi, STDERR
    call    asm_write

    pop     r12
    push    r12
    mov     rsi, [r15 + r12*8]
    mov     rdi, rsi
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, rdi
    mov     edi, STDERR
    call    asm_write

    lea     rsi, [rel str_paren_close_err]
    mov     edx, str_paren_close_err_len
    mov     edi, STDERR
    call    asm_write
    pop     r12

.kill_ok:
    inc     r12
    jmp     .pid_loop

.exit_with_status:
    mov     edi, ebp
    call    asm_exit

; ── Help ──────────────────────────────────────────────────
.do_help:
    mov     edi, STDOUT
    lea     rsi, [rel str_help]
    mov     edx, str_help_len
    call    asm_write
    xor     edi, edi
    call    asm_exit

; ── Version ───────────────────────────────────────────────
.do_version:
    mov     edi, STDOUT
    lea     rsi, [rel str_version]
    mov     edx, str_version_len
    call    asm_write
    xor     edi, edi
    call    asm_exit

; ── Errors ────────────────────────────────────────────────
.missing_operand:
    mov     edi, STDERR
    lea     rsi, [rel str_missing]
    mov     edx, str_missing_len
    call    asm_write
    mov     edi, STDERR
    lea     rsi, [rel str_try_help]
    mov     edx, str_try_help_len
    call    asm_write
    mov     edi, 1
    call    asm_exit

.invalid_signal:
    mov     edi, STDERR
    lea     rsi, [rel str_err_prefix]
    mov     edx, str_err_prefix_len
    call    asm_write
    mov     edi, STDERR
    lea     rsi, [rel str_invalid_sig]
    mov     edx, str_invalid_sig_len
    call    asm_write
    mov     edi, 1
    call    asm_exit

.invalid_signal_num:
    mov     edi, STDERR
    lea     rsi, [rel str_err_prefix]
    mov     edx, str_err_prefix_len
    call    asm_write
    mov     edi, STDERR
    lea     rsi, [rel str_invalid_sig]
    mov     edx, str_invalid_sig_len
    call    asm_write
    mov     edi, 1
    call    asm_exit

.invalid_pid:
    mov     edi, STDERR
    lea     rsi, [rel str_err_prefix]
    mov     edx, str_err_prefix_len
    call    asm_write
    ; Print "invalid PID" message with the argument
    push    r12
    mov     rsi, [r15 + r12*8]
    mov     rdi, rsi
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, rdi
    mov     edi, STDERR
    call    asm_write
    lea     rsi, [rel str_not_valid_pid]
    mov     edx, str_not_valid_pid_len
    mov     edi, STDERR
    call    asm_write
    pop     r12
    mov     edi, 1
    call    asm_exit

; ============================================================
; _atoi(rsi=str) -> rax=value, rdx=0 on success / 1 on error
; ============================================================
_atoi:
    xor     eax, eax
    xor     ecx, ecx            ; digit count
.atoi_loop:
    movzx   edx, byte [rsi]
    test    dl, dl
    jz      .atoi_done
    cmp     dl, '0'
    jb      .atoi_err
    cmp     dl, '9'
    ja      .atoi_err
    sub     dl, '0'
    imul    rax, 10
    movzx   edx, dl
    add     rax, rdx
    inc     rsi
    inc     ecx
    jmp     .atoi_loop
.atoi_done:
    test    ecx, ecx
    jz      .atoi_err
    xor     edx, edx
    ret
.atoi_err:
    xor     eax, eax
    mov     edx, 1
    ret

; ============================================================
; _parse_signal(rsi=str) -> rax=signum, rdx=0 ok / 1 error
; Accepts number or name (with or without SIG prefix)
; ============================================================
_parse_signal:
    push    rbx
    mov     rbx, rsi

    ; Try as number first
    call    _atoi
    test    edx, edx
    jz      .ps_num_ok

    ; Try as name
    mov     rsi, rbx
    call    _lookup_signal_name
    pop     rbx
    ret

.ps_num_ok:
    pop     rbx
    ret

; ============================================================
; _lookup_signal_name(rsi=name) -> rax=signum, rdx=0 ok/1 err
; Checks with and without "SIG" prefix, case-insensitive
; ============================================================
_lookup_signal_name:
    push    rbx
    push    r12
    mov     rbx, rsi

    ; Check if starts with "SIG" (case-insensitive)
    movzx   eax, byte [rsi]
    or      al, 0x20
    cmp     al, 's'
    jne     .lookup_no_prefix
    movzx   eax, byte [rsi+1]
    or      al, 0x20
    cmp     al, 'i'
    jne     .lookup_no_prefix
    movzx   eax, byte [rsi+2]
    or      al, 0x20
    cmp     al, 'g'
    jne     .lookup_no_prefix
    add     rsi, 3              ; skip "SIG"

.lookup_no_prefix:
    mov     rbx, rsi            ; name without prefix
    mov     r12, 1              ; signal number

.lookup_loop:
    cmp     r12, 31
    ja      .lookup_fail

    ; Get table entry
    mov     rax, r12
    dec     rax
    lea     rdi, [rel sig_name_table]
    shl     rax, 4
    add     rdi, rax

    ; Compare case-insensitive
    mov     rsi, rbx
    call    _strcasecmp
    test    eax, eax
    jz      .lookup_found

    inc     r12
    jmp     .lookup_loop

.lookup_found:
    mov     rax, r12
    xor     edx, edx
    pop     r12
    pop     rbx
    ret

.lookup_fail:
    xor     eax, eax
    mov     edx, 1
    pop     r12
    pop     rbx
    ret

; _strcasecmp(rdi=s1, rsi=s2) -> eax: 0=equal
_strcasecmp:
.loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    ; to uppercase both
    cmp     al, 'a'
    jb      .no_up1
    cmp     al, 'z'
    ja      .no_up1
    sub     al, 32
.no_up1:
    cmp     cl, 'a'
    jb      .no_up2
    cmp     cl, 'z'
    ja      .no_up2
    sub     cl, 32
.no_up2:
    cmp     al, cl
    jne     .diff
    test    al, al
    jz      .eq
    inc     rdi
    inc     rsi
    jmp     .loop
.eq:
    xor     eax, eax
    ret
.diff:
    sub     eax, ecx
    ret


section .rodata

str_help:
    db "Usage: kill [-s SIGNAL | -SIGNAL] PID...", 10
    db "  or:  kill -l [SIGNAL]...", 10
    db "  or:  kill --help", 10
    db "  or:  kill --version", 10
    db "Send signals to processes, or list signals.", 10, 10
    db "Options:", 10
    db "  -s SIGNAL   specify the signal to send", 10
    db "  -l          list signal names", 10
    db "  -l SIGNAL   convert signal number to name", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "SIGNAL may be a signal name like 'HUP', or a signal number like '1'.", 10
    db "PID is an integer; if negative it identifies a process group.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/kill>", 10
    db "or available locally via: info '(coreutils) kill invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "kill (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Paul Eggert.", 10
str_version_len equ $ - str_version

str_err_prefix:
    db "kill: "
str_err_prefix_len equ $ - str_err_prefix

str_missing:
    db "kill: not enough arguments", 10
str_missing_len equ $ - str_missing

str_try_help:
    db "Try 'kill --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_invalid_sig:
    db "invalid signal", 10
str_invalid_sig_len equ $ - str_invalid_sig

str_not_valid_pid:
    db ": arguments must be process or job IDs", 10
str_not_valid_pid_len equ $ - str_not_valid_pid

str_paren_open:
    db "("
str_paren_close_err:
    db ") - No such process", 10
str_paren_close_err_len equ $ - str_paren_close_err

str_paren_space:
    db ") "

newline:
    db 10

; Signal name table — 31 entries, each 16 bytes (padded with nulls)
sig_name_table:
    db "HUP",0,0,0,0,0,0,0,0,0,0,0,0,0           ; 1
    db "INT",0,0,0,0,0,0,0,0,0,0,0,0,0           ; 2
    db "QUIT",0,0,0,0,0,0,0,0,0,0,0,0             ; 3
    db "ILL",0,0,0,0,0,0,0,0,0,0,0,0,0           ; 4
    db "TRAP",0,0,0,0,0,0,0,0,0,0,0,0             ; 5
    db "ABRT",0,0,0,0,0,0,0,0,0,0,0,0             ; 6
    db "BUS",0,0,0,0,0,0,0,0,0,0,0,0,0           ; 7
    db "FPE",0,0,0,0,0,0,0,0,0,0,0,0,0           ; 8
    db "KILL",0,0,0,0,0,0,0,0,0,0,0,0             ; 9
    db "USR1",0,0,0,0,0,0,0,0,0,0,0,0             ; 10
    db "SEGV",0,0,0,0,0,0,0,0,0,0,0,0             ; 11
    db "USR2",0,0,0,0,0,0,0,0,0,0,0,0             ; 12
    db "PIPE",0,0,0,0,0,0,0,0,0,0,0,0             ; 13
    db "ALRM",0,0,0,0,0,0,0,0,0,0,0,0             ; 14
    db "TERM",0,0,0,0,0,0,0,0,0,0,0,0             ; 15
    db "STKFLT",0,0,0,0,0,0,0,0,0,0               ; 16
    db "CHLD",0,0,0,0,0,0,0,0,0,0,0,0             ; 17
    db "CONT",0,0,0,0,0,0,0,0,0,0,0,0             ; 18
    db "STOP",0,0,0,0,0,0,0,0,0,0,0,0             ; 19
    db "TSTP",0,0,0,0,0,0,0,0,0,0,0,0             ; 20
    db "TTIN",0,0,0,0,0,0,0,0,0,0,0,0             ; 21
    db "TTOU",0,0,0,0,0,0,0,0,0,0,0,0             ; 22
    db "URG",0,0,0,0,0,0,0,0,0,0,0,0,0           ; 23
    db "XCPU",0,0,0,0,0,0,0,0,0,0,0,0             ; 24
    db "XFSZ",0,0,0,0,0,0,0,0,0,0,0,0             ; 25
    db "VTALRM",0,0,0,0,0,0,0,0,0,0               ; 26
    db "PROF",0,0,0,0,0,0,0,0,0,0,0,0             ; 27
    db "WINCH",0,0,0,0,0,0,0,0,0,0,0              ; 28
    db "IO",0,0,0,0,0,0,0,0,0,0,0,0,0,0          ; 29
    db "PWR",0,0,0,0,0,0,0,0,0,0,0,0,0           ; 30
    db "SYS",0,0,0,0,0,0,0,0,0,0,0,0,0           ; 31

section .note.GNU-stack noalloc noexec nowrite progbits
