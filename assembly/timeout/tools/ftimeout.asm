; ftimeout.asm — GNU-compatible 'timeout' command
;
; timeout [OPTION] DURATION COMMAND [ARG]...
; Start COMMAND, and kill it if still running after DURATION.
;
; Options:
;   --foreground         don't create separate process group
;   -k DURATION          send KILL after this duration if still alive
;   -s SIGNAL            specify signal to send (default TERM)
;   --help / --version
;
; Uses: fork(57), execve(59), kill(62), waitpid(61), alarm(37),
;       rt_sigaction(13), nanosleep(35)

%include "include/linux.inc"

extern asm_write
extern asm_exit
extern asm_strlen
extern asm_strcmp

global _start

section .bss
    exec_argv: resq 257         ; argv for execve
    path_buf: resb 4096         ; PATH search buffer
    ; sigaction struct: 32 bytes (sa_handler/sa_sigaction, sa_flags, sa_restorer, sa_mask)
    sigact: resb 152
    sigact_old: resb 152

section .data
    child_pid: dq 0
    kill_signal: dd 15          ; SIGTERM by default
    kill_duration: dq 0         ; -k duration (seconds), 0 = disabled
    foreground: db 0            ; --foreground flag
    timed_out: db 0             ; set by alarm handler

section .text

; ============================================================
; Signal handler for SIGALRM — sets timed_out flag
; ============================================================
alarm_handler:
    mov     byte [rel timed_out], 1
    ret

; ============================================================
; Signal handler restorer (required by rt_sigaction)
; ============================================================
sig_restorer:
    mov     eax, 15             ; SYS_RT_SIGRETURN
    syscall

_start:
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv

    xor     r12d, r12d          ; duration seconds
    xor     r13d, r13d          ; duration nanoseconds
    mov     rbx, 1              ; arg index

    ; ── Scan for --help / --version ──
    cmp     r14, 2
    jl      .missing_operand
    mov     rdi, [r15 + 8]
    mov     rsi, str_opt_help
    call    asm_strcmp
    test    eax, eax
    jz      .show_help
    mov     rdi, [r15 + 8]
    mov     rsi, str_opt_version
    call    asm_strcmp
    test    eax, eax
    jz      .show_version

.parse_options:
    cmp     rbx, r14
    jge     .missing_operand

    mov     rdi, [r15 + rbx*8]

    ; Check for option flags
    cmp     byte [rdi], '-'
    jne     .parse_duration

    ; --foreground
    push    rbx
    mov     rsi, str_opt_foreground
    call    asm_strcmp
    pop     rbx
    test    eax, eax
    jz      .set_foreground

    mov     rdi, [r15 + rbx*8]

    ; -s SIGNAL
    cmp     byte [rdi + 1], 's'
    jne     .check_k
    cmp     byte [rdi + 2], 0
    jne     .check_signal_attached

    ; -s SIGNAL (space-separated)
    inc     rbx
    cmp     rbx, r14
    jge     .missing_operand
    mov     rdi, [r15 + rbx*8]
    call    parse_signal
    mov     [rel kill_signal], eax
    inc     rbx
    jmp     .parse_options

.check_signal_attached:
    ; -sSIGNAL (attached)
    lea     rdi, [rdi + 2]
    call    parse_signal
    mov     [rel kill_signal], eax
    inc     rbx
    jmp     .parse_options

.check_k:
    ; -k DURATION
    cmp     byte [rdi + 1], 'k'
    jne     .check_signal_long
    cmp     byte [rdi + 2], 0
    jne     .check_k_attached

    inc     rbx
    cmp     rbx, r14
    jge     .missing_operand
    mov     rdi, [r15 + rbx*8]
    call    parse_duration
    mov     [rel kill_duration], rax
    inc     rbx
    jmp     .parse_options

.check_k_attached:
    lea     rdi, [rdi + 2]
    call    parse_duration
    mov     [rel kill_duration], rax
    inc     rbx
    jmp     .parse_options

.check_signal_long:
    ; --signal=
    push    rbx
    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_signal_eq
    call    starts_with
    pop     rbx
    test    eax, eax
    jnz     .parse_signal_eq

    ; --kill-after=
    push    rbx
    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_kill_eq
    call    starts_with
    pop     rbx
    test    eax, eax
    jnz     .parse_kill_eq

    ; -- (end of options)
    mov     rdi, [r15 + rbx*8]
    cmp     byte [rdi + 1], '-'
    jne     .invalid_option
    cmp     byte [rdi + 2], 0
    jne     .invalid_option
    inc     rbx
    jmp     .parse_duration

.parse_signal_eq:
    mov     rdi, [r15 + rbx*8]
.find_eq_sig:
    cmp     byte [rdi], '='
    je      .found_eq_sig
    inc     rdi
    jmp     .find_eq_sig
.found_eq_sig:
    inc     rdi
    call    parse_signal
    mov     [rel kill_signal], eax
    inc     rbx
    jmp     .parse_options

.parse_kill_eq:
    mov     rdi, [r15 + rbx*8]
.find_eq_kill:
    cmp     byte [rdi], '='
    je      .found_eq_kill
    inc     rdi
    jmp     .find_eq_kill
.found_eq_kill:
    inc     rdi
    call    parse_duration
    mov     [rel kill_duration], rax
    inc     rbx
    jmp     .parse_options

.set_foreground:
    mov     byte [rel foreground], 1
    inc     rbx
    jmp     .parse_options

.parse_duration:
    ; Current arg is the duration
    cmp     rbx, r14
    jge     .missing_operand
    mov     rdi, [r15 + rbx*8]
    call    parse_duration
    mov     r12, rax            ; duration seconds
    inc     rbx

    ; Next args are the command
    cmp     rbx, r14
    jge     .missing_operand

    ; Build argv for exec
    mov     rcx, 0
.build_argv:
    cmp     rbx, r14
    jge     .argv_done
    mov     rax, [r15 + rbx*8]
    mov     [rel exec_argv + rcx*8], rax
    inc     rcx
    inc     rbx
    cmp     rcx, 256
    jge     .argv_done
    jmp     .build_argv
.argv_done:
    mov     qword [rel exec_argv + rcx*8], 0

    ; Get envp
    mov     rax, [rsp]
    lea     rdx, [rsp + 8]
    lea     rdx, [rdx + rax*8 + 8]
    mov     rbp, rdx            ; rbp = envp

    ; Duration 0 means never timeout — just exec
    test    r12, r12
    jz      .duration_zero

    ; ── Install SIGALRM handler ──
    lea     rax, [rel alarm_handler]
    mov     [rel sigact], rax       ; sa_handler
    mov     qword [rel sigact + 8], SA_RESTORER  ; sa_flags (no SA_RESTART so wait4 returns -EINTR)
    lea     rax, [rel sig_restorer]
    mov     [rel sigact + 16], rax  ; sa_restorer
    ; Zero out sa_mask (128 bits = 16 bytes)
    xor     eax, eax
    mov     [rel sigact + 24], rax
    mov     [rel sigact + 32], rax

    mov     eax, SYS_RT_SIGACTION
    mov     edi, SIGALRM
    lea     rsi, [rel sigact]
    lea     rdx, [rel sigact_old]
    mov     r10, 8              ; sigsetsize
    syscall

    ; ── Fork ──
    mov     eax, SYS_FORK
    syscall
    test    rax, rax
    js      .fork_failed
    jz      .child_process

    ; ── Parent process ──
    mov     [rel child_pid], rax

    ; Set process group if not --foreground
    cmp     byte [rel foreground], 0
    jne     .skip_setpgid
    mov     edi, eax            ; child pid
    mov     esi, eax            ; pgid = child pid
    mov     eax, SYS_SETPGID
    syscall
.skip_setpgid:

    ; Set alarm for duration
    mov     edi, r12d           ; seconds
    mov     eax, SYS_ALARM
    syscall

    ; Wait for child
.wait_loop:
    sub     rsp, 8              ; status
    mov     rdi, [rel child_pid]
    mov     rsi, rsp            ; &status
    xor     edx, edx            ; options
    xor     r10, r10            ; rusage
    mov     eax, SYS_WAIT4
    syscall

    cmp     rax, -4             ; EINTR
    jne     .wait_done

    ; Check if timed out
    cmp     byte [rel timed_out], 0
    je      .wait_retry

    ; Timed out — send signal to child
    mov     rdi, [rel child_pid]
    cmp     byte [rel foreground], 0
    jne     .kill_child
    neg     rdi                 ; kill process group
.kill_child:
    mov     esi, [rel kill_signal]
    mov     eax, SYS_KILL
    syscall

    ; If -k specified, set another alarm and wait
    mov     rax, [rel kill_duration]
    test    rax, rax
    jz      .wait_for_death

    ; Set alarm for kill duration
    mov     edi, eax
    mov     eax, SYS_ALARM
    syscall
    mov     byte [rel timed_out], 0

.wait_for_death:
    ; Wait for child to exit
    mov     rdi, [rel child_pid]
    mov     rsi, rsp
    xor     edx, edx
    xor     r10, r10
    mov     eax, SYS_WAIT4
    syscall

    cmp     rax, -4             ; EINTR
    jne     .wait_done_timeout

    ; Second timeout — send SIGKILL
    cmp     byte [rel timed_out], 0
    je      .wait_for_death

    mov     rdi, [rel child_pid]
    cmp     byte [rel foreground], 0
    jne     .kill9_child
    neg     rdi
.kill9_child:
    mov     esi, SIGKILL
    mov     eax, SYS_KILL
    syscall

    ; Final wait
    mov     rdi, [rel child_pid]
    mov     rsi, rsp
    xor     edx, edx
    xor     r10, r10
    mov     eax, SYS_WAIT4
    syscall
    jmp     .wait_done_timeout

.wait_retry:
    add     rsp, 8
    jmp     .wait_loop

.wait_done_timeout:
    ; Exit with 124 (timed out)
    pop     rax                 ; clean up status
    mov     edi, 124
    call    asm_exit

.wait_done:
    ; Child exited — extract exit code
    cmp     rax, 0
    jl      .wait_error
    pop     rax                 ; status
    ; Cancel alarm
    push    rax
    xor     edi, edi
    mov     eax, SYS_ALARM
    syscall
    pop     rax

    ; Check if child was signaled: status & 0x7f != 0
    mov     edx, eax
    and     edx, 0x7f
    test    edx, edx
    jnz     .child_signaled

    ; Normal exit: status >> 8
    shr     eax, 8
    and     eax, 0xff
    mov     edi, eax
    call    asm_exit

.child_signaled:
    ; Signal exit: 128 + signal_number
    mov     edi, edx
    add     edi, 128
    call    asm_exit

.wait_error:
    add     rsp, 8
    mov     edi, 125
    call    asm_exit

.duration_zero:
    ; Duration is 0 — just exec directly (no timeout)
    ; Actually GNU timeout with duration 0 sends signal immediately
    ; Fork, exec, then immediately signal
    mov     eax, SYS_FORK
    syscall
    test    rax, rax
    js      .fork_failed
    jz      .child_process

    mov     [rel child_pid], rax

    ; Immediately kill the child
    mov     rdi, rax
    mov     esi, [rel kill_signal]
    mov     eax, SYS_KILL
    syscall

    ; Wait for child
    sub     rsp, 8
    mov     rdi, [rel child_pid]
    mov     rsi, rsp
    xor     edx, edx
    xor     r10, r10
    mov     eax, SYS_WAIT4
    syscall
    pop     rax

    ; Exit 124 (timed out)
    mov     edi, 124
    call    asm_exit

.child_process:
    ; In child — exec the command
    ; Set own process group if not --foreground
    cmp     byte [rel foreground], 0
    jne     .child_exec
    xor     edi, edi            ; pid=0 (self)
    xor     esi, esi            ; pgid=0 (own pid)
    mov     eax, SYS_SETPGID
    syscall

.child_exec:
    mov     rdi, [rel exec_argv]
    lea     rsi, [rel exec_argv]
    mov     rdx, rbp            ; envp
    mov     eax, SYS_EXECVE
    syscall

    ; If direct exec failed, try PATH search
    cmp     rax, -2             ; ENOENT
    je      .child_path
    cmp     rax, -13            ; EACCES
    je      .child_path
    cmp     rax, -20            ; ENOTDIR
    je      .child_path
    jmp     .child_exec_fail

.child_path:
    mov     rdi, rbp            ; envp
    call    find_path_env
    test    rax, rax
    jz      .child_not_found
    mov     r8, rax             ; PATH value
    mov     r9, [rel exec_argv] ; command name

.child_path_loop:
    cmp     byte [r8], 0
    je      .child_not_found

    lea     rdi, [rel path_buf]
    mov     rcx, 0
.child_copy_path:
    movzx   eax, byte [r8]
    cmp     al, ':'
    je      .child_path_sep
    test    al, al
    jz      .child_path_sep
    mov     [rdi + rcx], al
    inc     rcx
    inc     r8
    cmp     rcx, 4000
    jge     .child_path_sep
    jmp     .child_copy_path
.child_path_sep:
    cmp     byte [r8], ':'
    jne     .child_no_skip
    inc     r8
.child_no_skip:
    mov     byte [rdi + rcx], '/'
    inc     rcx
    push    r8
    mov     rsi, r9
.child_copy_cmd:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .child_cmd_done
    mov     [rdi + rcx], al
    inc     rcx
    inc     rsi
    cmp     rcx, 4090
    jge     .child_cmd_done
    jmp     .child_copy_cmd
.child_cmd_done:
    mov     byte [rdi + rcx], 0
    pop     r8

    lea     rdi, [rel path_buf]
    lea     rsi, [rel exec_argv]
    mov     rdx, rbp
    mov     eax, SYS_EXECVE
    syscall
    jmp     .child_path_loop

.child_not_found:
    mov     edi, STDERR
    mov     rsi, str_err_prefix
    mov     edx, str_err_prefix_len
    call    asm_write
    mov     rdi, [rel exec_argv]
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, [rel exec_argv]
    mov     edi, STDERR
    call    asm_write
    mov     edi, STDERR
    mov     rsi, str_enoent
    mov     edx, str_enoent_len
    call    asm_write
    mov     edi, 127
    call    asm_exit

.child_exec_fail:
    mov     edi, STDERR
    mov     rsi, str_err_prefix
    mov     edx, str_err_prefix_len
    call    asm_write
    mov     rdi, [rel exec_argv]
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, [rel exec_argv]
    mov     edi, STDERR
    call    asm_write
    mov     edi, STDERR
    mov     rsi, str_eperm
    mov     edx, str_eperm_len
    call    asm_write
    mov     edi, 126
    call    asm_exit

.fork_failed:
    mov     edi, STDERR
    mov     rsi, str_fork_err
    mov     edx, str_fork_err_len
    call    asm_write
    mov     edi, 125
    call    asm_exit

.show_help:
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    asm_write
    xor     edi, edi
    call    asm_exit

.show_version:
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    asm_write
    xor     edi, edi
    call    asm_exit

.missing_operand:
    mov     edi, STDERR
    mov     rsi, str_missing
    mov     edx, str_missing_len
    call    asm_write
    mov     edi, STDERR
    mov     rsi, str_try
    mov     edx, str_try_len
    call    asm_write
    mov     edi, 125
    call    asm_exit

.invalid_option:
    mov     edi, STDERR
    mov     rsi, str_inv_opt_pre
    mov     edx, str_inv_opt_pre_len
    call    asm_write
    mov     rdi, [r15 + rbx*8]
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, [r15 + rbx*8]
    mov     edi, STDERR
    call    asm_write
    mov     edi, STDERR
    mov     rsi, str_inv_opt_post
    mov     edx, str_inv_opt_post_len
    call    asm_write
    mov     edi, STDERR
    mov     rsi, str_try
    mov     edx, str_try_len
    call    asm_write
    mov     edi, 125
    call    asm_exit

; ============================================================
; parse_duration(rdi=str) -> rax = seconds (integer)
; Supports NUMBER[smhd] format
; ============================================================
parse_duration:
    push    rbx
    xor     eax, eax
    xor     ecx, ecx            ; has_digits
.pd_loop:
    movzx   edx, byte [rdi]
    cmp     dl, '0'
    jb      .pd_suffix
    cmp     dl, '9'
    ja      .pd_suffix
    sub     dl, '0'
    imul    rax, 10
    movzx   edx, dl
    add     rax, rdx
    inc     ecx
    inc     rdi
    jmp     .pd_loop
.pd_suffix:
    test    ecx, ecx
    jz      .pd_default         ; no digits = default 0
    movzx   edx, byte [rdi]
    test    dl, dl
    jz      .pd_done            ; no suffix = seconds
    cmp     dl, 's'
    je      .pd_done
    cmp     dl, 'm'
    je      .pd_min
    cmp     dl, 'h'
    je      .pd_hour
    cmp     dl, 'd'
    je      .pd_day
    ; Skip dot and fractional part
    cmp     dl, '.'
    je      .pd_skip_frac
    jmp     .pd_done
.pd_skip_frac:
    inc     rdi
.pd_skip_frac_loop:
    movzx   edx, byte [rdi]
    cmp     dl, '0'
    jb      .pd_check_suffix
    cmp     dl, '9'
    ja      .pd_check_suffix
    inc     rdi
    jmp     .pd_skip_frac_loop
.pd_check_suffix:
    movzx   edx, byte [rdi]
    cmp     dl, 's'
    je      .pd_done
    cmp     dl, 'm'
    je      .pd_min
    cmp     dl, 'h'
    je      .pd_hour
    cmp     dl, 'd'
    je      .pd_day
    jmp     .pd_done
.pd_min:
    imul    rax, 60
    jmp     .pd_done
.pd_hour:
    imul    rax, 3600
    jmp     .pd_done
.pd_day:
    imul    rax, 86400
    jmp     .pd_done
.pd_default:
    xor     eax, eax
.pd_done:
    pop     rbx
    ret

; ============================================================
; parse_signal(rdi=str) -> eax = signal number
; Accepts numeric or "TERM", "KILL", "INT", "HUP" etc.
; ============================================================
parse_signal:
    push    rbx
    ; Try numeric first
    movzx   eax, byte [rdi]
    cmp     al, '0'
    jb      .ps_name
    cmp     al, '9'
    ja      .ps_name
    ; Numeric
    xor     eax, eax
.ps_num:
    movzx   edx, byte [rdi]
    test    dl, dl
    jz      .ps_done
    cmp     dl, '0'
    jb      .ps_done
    cmp     dl, '9'
    ja      .ps_done
    sub     dl, '0'
    imul    eax, 10
    add     eax, edx
    inc     rdi
    jmp     .ps_num

.ps_name:
    ; Skip "SIG" prefix if present
    cmp     byte [rdi], 'S'
    jne     .ps_check_name
    cmp     byte [rdi + 1], 'I'
    jne     .ps_check_name
    cmp     byte [rdi + 2], 'G'
    jne     .ps_check_name
    add     rdi, 3

.ps_check_name:
    push    rdi
    mov     rsi, str_sig_term
    call    asm_strcmp
    pop     rdi
    test    eax, eax
    jz      .ps_term

    push    rdi
    mov     rsi, str_sig_kill
    call    asm_strcmp
    pop     rdi
    test    eax, eax
    jz      .ps_kill

    push    rdi
    mov     rsi, str_sig_int
    call    asm_strcmp
    pop     rdi
    test    eax, eax
    jz      .ps_int

    push    rdi
    mov     rsi, str_sig_hup
    call    asm_strcmp
    pop     rdi
    test    eax, eax
    jz      .ps_hup

    ; Default: SIGTERM
    mov     eax, SIGTERM
    jmp     .ps_done

.ps_term:
    mov     eax, SIGTERM
    jmp     .ps_done
.ps_kill:
    mov     eax, SIGKILL
    jmp     .ps_done
.ps_int:
    mov     eax, SIGINT
    jmp     .ps_done
.ps_hup:
    mov     eax, SIGHUP

.ps_done:
    pop     rbx
    ret

; ============================================================
; starts_with(rdi=str, rsi=prefix) -> eax: 1=match, 0=no
; ============================================================
starts_with:
.loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .match
    movzx   ecx, byte [rdi]
    cmp     al, cl
    jne     .no_match
    inc     rdi
    inc     rsi
    jmp     .loop
.match:
    mov     eax, 1
    ret
.no_match:
    xor     eax, eax
    ret

; ============================================================
; find_path_env(rdi=envp) -> rax = PATH value or 0
; ============================================================
find_path_env:
.loop:
    mov     rax, [rdi]
    test    rax, rax
    jz      .not_found
    cmp     dword [rax], 0x48544150     ; "PATH"
    jne     .next
    cmp     byte [rax + 4], '='
    jne     .next
    lea     rax, [rax + 5]
    ret
.next:
    add     rdi, 8
    jmp     .loop
.not_found:
    xor     eax, eax
    ret


section .rodata

str_opt_help:
    db "--help", 0
str_opt_version:
    db "--version", 0
str_opt_foreground:
    db "--foreground", 0
str_opt_signal_eq:
    db "--signal=", 0
str_opt_kill_eq:
    db "--kill-after=", 0

str_sig_term:
    db "TERM", 0
str_sig_kill:
    db "KILL", 0
str_sig_int:
    db "INT", 0
str_sig_hup:
    db "HUP", 0

str_help:
    db "Usage: timeout [OPTION] DURATION COMMAND [ARG]...", 10
    db "  or:  timeout [OPTION]", 10
    db "Start COMMAND, and kill it if still running after DURATION.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "      --foreground   don't create a separate background process group", 10
    db "  -k, --kill-after=DURATION", 10
    db "                     also send a KILL signal if COMMAND is still running", 10
    db "                     this long after the initial signal was sent", 10
    db "  -s, --signal=SIGNAL", 10
    db "                     specify the signal to be sent on timeout;", 10
    db "                     SIGNAL may be a name like 'HUP' or a number;", 10
    db "                     see 'kill -l' for a list of signals", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "DURATION is a floating point number with an optional suffix:", 10
    db "'s' for seconds (the default), 'm' for minutes, 'h' for hours", 10
    db "or 'd' for days.  A duration of 0 disables the associated timeout.", 10
    db 10
    db "Upon timeout, send the TERM signal to COMMAND, if no other SIGNAL specified.", 10
    db "The TERM signal kills any process that does not block or catch that signal.", 10
    db "It may be necessary to use the KILL signal, since this signal can't be caught.", 10
    db 10
    db "Exit status:", 10
    db "  124  if COMMAND times out, and --preserve-status is not specified", 10
    db "  125  if the timeout command itself fails", 10
    db "  126  if COMMAND is found but cannot be invoked", 10
    db "  127  if COMMAND cannot be found", 10
    db "  137  if COMMAND (or timeout itself) is sent the KILL (9) signal (128+9)", 10
    db "  the exit status of COMMAND otherwise", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/timeout>", 10
    db "or available locally via: info '(coreutils) timeout invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "timeout (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by Padraig Brady.", 10
str_version_len equ $ - str_version

str_try:
    db "Try 'timeout --help' for more information.", 10
str_try_len equ $ - str_try

str_missing:
    db "timeout: missing operand", 10
str_missing_len equ $ - str_missing

str_err_prefix:
    db "timeout: ", 0
str_err_prefix_len equ $ - str_err_prefix - 1

str_enoent:
    db ": No such file or directory", 10
str_enoent_len equ $ - str_enoent

str_eperm:
    db ": Permission denied", 10
str_eperm_len equ $ - str_eperm

str_fork_err:
    db "timeout: fork: Cannot allocate memory", 10
str_fork_err_len equ $ - str_fork_err

str_inv_opt_pre:
    db "timeout: unrecognized option '", 0
str_inv_opt_pre_len equ $ - str_inv_opt_pre - 1

str_inv_opt_post:
    db "'", 10, 0
str_inv_opt_post_len equ $ - str_inv_opt_post - 1

; Non-executable stack
section .note.GNU-stack noalloc noexec nowrite progbits
