; flogname.asm - print the user's login name (GNU-compatible)
;
; Implements getlogin() behavior:
;   1. Try /proc/self/loginuid -> look up UID in /etc/passwd
;   2. Try utmp: get tty name, search /var/run/utmp
;   3. Fail with "logname: no login name"

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write
extern asm_write_err
extern asm_exit
extern asm_read
extern str_len
extern str_eq
extern check_flag

global _start

section .data

; GNU-identical --help output (429 bytes)
str_help:
    db "Usage: logname [OPTION]", 10
    db "Print the user's login name.", 10
    db 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Report any translation bugs to <https://translationproject.org/team/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/logname>", 10
    db "or available locally via: info '(coreutils) logname invocation'", 10
str_help_len equ $ - str_help

; GNU-identical --version output (307 bytes)
str_version:
    db "logname (GNU coreutils) 9.4", 10
    db "Copyright (C) 2023 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by FIXME: unknown.", 10
str_version_len equ $ - str_version

; Error message fragments
str_prefix:      db "logname: "
str_prefix_len   equ $ - str_prefix

str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog

str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid

str_extra:       db "extra operand '"
str_extra_len    equ $ - str_extra

str_sq_nl:       db "'", 10
str_sq_nl_len    equ 2

str_try:         db "Try 'logname --help' for more information.", 10
str_try_len      equ $ - str_try

str_no_login:    db "logname: no login name", 10
str_no_login_len equ $ - str_no_login

str_newline:     db 10

; File paths
path_loginuid:   db "/proc/self/loginuid", 0
path_passwd:     db "/etc/passwd", 0
path_utmp:       db "/var/run/utmp", 0
path_fd0:        db "/proc/self/fd/0", 0

; String constants
str_help_flag:    db "--help", 0
str_version_flag: db "--version", 0
str_invalid_uid:  db "4294967295", 0
str_dev_prefix:   db "/dev/", 0

section .bss
    read_buf:    resb 4096      ; General read buffer
    name_buf:    resb 256       ; Login name result
    uid_str:     resb 32        ; UID string from loginuid
    tty_buf:     resb 256       ; TTY path from readlink
    utmp_entry:  resb UTMP_ENTRY_SIZE  ; Single utmp entry

section .text

_start:
    ; Get argc/argv from stack
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv

    ; If argc <= 1, do logname
    cmp     r14, 1
    jbe     .do_logname

    ; Process argv[1]
    mov     r13, [r15 + 8]      ; argv[1]

    ; Check if starts with '-'
    cmp     byte [r13], '-'
    jne     .err_extra_operand

    ; Check second character
    cmp     byte [r13 + 1], '-'
    je      .check_long_option

    ; Single dash: check for bare "-"
    cmp     byte [r13 + 1], 0
    je      .err_extra_operand  ; bare "-" is an operand

    ; Short option error: "invalid option -- 'c'"
    jmp     .err_invalid_option

.check_long_option:
    ; Starts with "--"
    ; Check for bare "--" (end of options)
    cmp     byte [r13 + 2], 0
    je      .handle_double_dash

    ; Check for --help
    mov     rdi, r13
    mov     rsi, str_help_flag
    call    check_flag
    test    rax, rax
    jnz     .show_help

    ; Check for --version
    mov     rdi, r13
    mov     rsi, str_version_flag
    call    check_flag
    test    rax, rax
    jnz     .show_version

    ; Unknown long option
    jmp     .err_unrecognized

.handle_double_dash:
    ; "--" terminates option processing
    ; If more args exist, they are operands (error)
    cmp     r14, 2
    jbe     .do_logname
    ; argv[2] is an extra operand
    mov     r13, [r15 + 16]     ; argv[2]
    jmp     .err_extra_operand

; ── Output handlers ──────────────────────────────────────────

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

; ── Error handlers ───────────────────────────────────────────

.err_unrecognized:
    ; "logname: unrecognized option 'ARG'\n"
    mov     rsi, str_prefix
    mov     rdx, str_prefix_len
    call    asm_write_err

    mov     rsi, str_unrecog
    mov     rdx, str_unrecog_len
    call    asm_write_err

    ; Write the argument string
    mov     rdi, r13
    call    str_len
    mov     rdx, rax
    mov     rsi, r13
    call    asm_write_err

    mov     rsi, str_sq_nl
    mov     rdx, str_sq_nl_len
    call    asm_write_err
    jmp     .err_try_exit

.err_invalid_option:
    ; "logname: invalid option -- 'c'\n"
    mov     rsi, str_prefix
    mov     rdx, str_prefix_len
    call    asm_write_err

    mov     rsi, str_invalid
    mov     rdx, str_invalid_len
    call    asm_write_err

    ; Write single char: argv[1][1]
    lea     rsi, [r13 + 1]
    mov     rdx, 1
    call    asm_write_err

    mov     rsi, str_sq_nl
    mov     rdx, str_sq_nl_len
    call    asm_write_err
    jmp     .err_try_exit

.err_extra_operand:
    ; "logname: extra operand 'ARG'\n"
    mov     rsi, str_prefix
    mov     rdx, str_prefix_len
    call    asm_write_err

    mov     rsi, str_extra
    mov     rdx, str_extra_len
    call    asm_write_err

    ; Write the operand string
    mov     rdi, r13
    call    str_len
    mov     rdx, rax
    mov     rsi, r13
    call    asm_write_err

    mov     rsi, str_sq_nl
    mov     rdx, str_sq_nl_len
    call    asm_write_err
    jmp     .err_try_exit

.err_try_exit:
    mov     rsi, str_try
    mov     rdx, str_try_len
    call    asm_write_err
    mov     rdi, 1
    call    asm_exit

; ── Main logname logic ───────────────────────────────────────

.do_logname:
    ; Method 1: Try /proc/self/loginuid
    call    try_loginuid
    test    rax, rax
    jnz     .print_name

    ; Method 2: Try utmp
    call    try_utmp
    test    rax, rax
    jnz     .print_name

    ; All methods failed
    mov     rsi, str_no_login
    mov     rdx, str_no_login_len
    call    asm_write_err
    mov     rdi, 1
    call    asm_exit

.print_name:
    ; rax = pointer to null-terminated name string
    mov     r12, rax

    ; Get length
    mov     rdi, r12
    call    str_len
    mov     rdx, rax

    ; Write name to stdout
    mov     rdi, STDOUT
    mov     rsi, r12
    call    asm_write

    ; Write newline
    mov     rdi, STDOUT
    mov     rsi, str_newline
    mov     rdx, 1
    call    asm_write

    ; Exit success
    xor     rdi, rdi
    call    asm_exit

; ══════════════════════════════════════════════════════════════
; Method 1: /proc/self/loginuid -> /etc/passwd lookup
; Returns: rax = pointer to name_buf if found, 0 if not
; ══════════════════════════════════════════════════════════════

try_loginuid:
    push    rbx
    push    r12
    push    r13

    ; Open /proc/self/loginuid
    mov     rax, SYS_OPEN
    mov     rdi, path_loginuid
    xor     rsi, rsi            ; O_RDONLY
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .loginuid_fail

    mov     r12, rax            ; save fd

    ; Read UID string
    mov     rdi, r12
    mov     rsi, uid_str
    mov     rdx, 31
    call    asm_read

    ; Close fd regardless
    push    rax
    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall
    pop     rax

    ; Check read result
    test    rax, rax
    jle     .loginuid_fail

    ; Null-terminate and strip trailing newline
    mov     r12, rax            ; bytes read
    mov     byte [uid_str + r12], 0
    dec     r12
    cmp     byte [uid_str + r12], 10
    jne     .loginuid_no_trim
    mov     byte [uid_str + r12], 0
.loginuid_no_trim:

    ; Check if UID is 4294967295 (invalid/nobody)
    mov     rdi, uid_str
    mov     rsi, str_invalid_uid
    call    str_eq
    test    rax, rax
    jnz     .loginuid_fail

    ; Open /etc/passwd
    mov     rax, SYS_OPEN
    mov     rdi, path_passwd
    xor     rsi, rsi            ; O_RDONLY
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .loginuid_fail

    mov     r12, rax            ; fd

    ; Scan /etc/passwd for matching UID
    call    scan_passwd

    ; Close fd
    push    rax
    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall
    pop     rax

    pop     r13
    pop     r12
    pop     rbx
    ret

.loginuid_fail:
    xor     rax, rax
    pop     r13
    pop     r12
    pop     rbx
    ret

; ══════════════════════════════════════════════════════════════
; Scan /etc/passwd for UID matching uid_str
; r12 = fd
; Returns: rax = pointer to name_buf if found, 0 if not
; ══════════════════════════════════════════════════════════════

scan_passwd:
    push    rbx
    push    r13
    push    r14
    push    r15
    push    rbp

    xor     rbp, rbp            ; leftover bytes from previous read

.passwd_read_chunk:
    ; Read into buffer (after any leftover bytes)
    mov     rdi, r12
    lea     rsi, [read_buf + rbp]
    mov     rdx, 4095
    sub     rdx, rbp
    jle     .passwd_not_found   ; buffer full, line too long
    call    asm_read
    test    rax, rax
    jle     .passwd_check_leftover

    add     rbp, rax            ; total bytes in buffer
    xor     r13, r13            ; scan position

.passwd_scan_line:
    cmp     r13, rbp
    jge     .passwd_need_more

    ; Find end of current line
    mov     r14, r13            ; line start
.passwd_find_nl:
    cmp     r14, rbp
    jge     .passwd_need_more_partial
    cmp     byte [read_buf + r14], 10
    je      .passwd_got_line
    inc     r14
    jmp     .passwd_find_nl

.passwd_got_line:
    ; Line is from r13 to r14 (exclusive of newline)
    ; Find 3rd field (UID): skip 2 colons
    mov     rcx, r13
    xor     rbx, rbx            ; colon count

.passwd_find_uid_field:
    cmp     rcx, r14
    jge     .passwd_next_line
    cmp     byte [read_buf + rcx], ':'
    jne     .passwd_skip_char
    inc     rbx
    cmp     rbx, 2
    je      .passwd_uid_start
.passwd_skip_char:
    inc     rcx
    jmp     .passwd_find_uid_field

.passwd_uid_start:
    inc     rcx                 ; skip the colon
    mov     r15, rcx            ; UID field start

    ; Find end of UID field (next colon)
.passwd_uid_end:
    cmp     rcx, r14
    jge     .passwd_next_line
    cmp     byte [read_buf + rcx], ':'
    je      .passwd_compare_uid
    inc     rcx
    jmp     .passwd_uid_end

.passwd_compare_uid:
    ; UID field: read_buf[r15..rcx)
    ; Compare with uid_str
    push    rcx
    mov     rdi, uid_str
    call    str_len             ; rax = length of uid_str
    pop     rcx

    ; Check length match
    mov     rdx, rcx
    sub     rdx, r15            ; length of UID field in passwd
    cmp     rax, rdx
    jne     .passwd_next_line

    ; Compare bytes
    xor     rbx, rbx
.passwd_cmp_byte:
    cmp     rbx, rax
    je      .passwd_uid_match
    movzx   edx, byte [read_buf + r15 + rbx]
    cmp     dl, byte [uid_str + rbx]
    jne     .passwd_next_line
    inc     rbx
    jmp     .passwd_cmp_byte

.passwd_uid_match:
    ; Extract username: from line start (r13) to first colon
    lea     rsi, [read_buf + r13]
    mov     rdi, name_buf
    xor     rcx, rcx
.passwd_copy_name:
    cmp     byte [rsi + rcx], ':'
    je      .passwd_name_done
    cmp     rcx, 255            ; bounds check
    jge     .passwd_name_done
    mov     al, [rsi + rcx]
    mov     [rdi + rcx], al
    inc     rcx
    jmp     .passwd_copy_name
.passwd_name_done:
    mov     byte [rdi + rcx], 0 ; null-terminate
    mov     rax, name_buf

    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

.passwd_next_line:
    lea     r13, [r14 + 1]      ; skip newline
    jmp     .passwd_scan_line

.passwd_need_more_partial:
    ; Incomplete line at end of buffer
    ; Move leftover bytes to start of buffer
    mov     rcx, rbp
    sub     rcx, r13            ; leftover bytes
    test    rcx, rcx
    jz      .passwd_no_leftover

    ; Move bytes from r13 to start of read_buf
    push    rsi
    push    rdi
    lea     rsi, [read_buf + r13]
    mov     rdi, read_buf
    mov     rbp, rcx
    rep     movsb
    pop     rdi
    pop     rsi
    jmp     .passwd_read_chunk

.passwd_no_leftover:
    xor     rbp, rbp
.passwd_need_more:
    xor     rbp, rbp
    jmp     .passwd_read_chunk

.passwd_check_leftover:
    ; End of file; check if there's a leftover partial line
    test    rbp, rbp
    jz      .passwd_not_found
    ; Process remaining as a line (no trailing newline)
    mov     r13, 0
    mov     r14, rbp
    jmp     .passwd_got_line

.passwd_not_found:
    xor     rax, rax
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; ══════════════════════════════════════════════════════════════
; Method 2: utmp lookup
; Returns: rax = pointer to name_buf if found, 0 if not
; ══════════════════════════════════════════════════════════════

try_utmp:
    push    rbx
    push    r12
    push    r13

    ; Get tty name via readlink /proc/self/fd/0
    mov     rax, SYS_READLINK
    mov     rdi, path_fd0
    mov     rsi, tty_buf
    mov     rdx, 255
    syscall
    test    rax, rax
    jle     .utmp_fail

    ; Null-terminate
    mov     byte [tty_buf + rax], 0

    ; Check if starts with /dev/
    cmp     byte [tty_buf], '/'
    jne     .utmp_fail
    cmp     byte [tty_buf + 1], 'd'
    jne     .utmp_fail
    cmp     byte [tty_buf + 2], 'e'
    jne     .utmp_fail
    cmp     byte [tty_buf + 3], 'v'
    jne     .utmp_fail
    cmp     byte [tty_buf + 4], '/'
    jne     .utmp_fail

    ; tty name = tty_buf + 5 (strip /dev/ prefix)
    lea     r13, [tty_buf + 5]

    ; Open /var/run/utmp
    mov     rax, SYS_OPEN
    mov     rdi, path_utmp
    xor     rsi, rsi            ; O_RDONLY
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .utmp_fail

    mov     r12, rax            ; fd

.utmp_read_entry:
    ; Read one utmp entry (384 bytes)
    mov     rdi, r12
    mov     rsi, utmp_entry
    mov     rdx, UTMP_ENTRY_SIZE
    call    asm_read
    cmp     rax, UTMP_ENTRY_SIZE
    jne     .utmp_close_fail

    ; Check ut_type == USER_PROCESS (7)
    movzx   eax, word [utmp_entry + UTMP_TYPE_OFF]
    cmp     eax, USER_PROCESS
    jne     .utmp_read_entry

    ; Compare ut_line with our tty name
    lea     rdi, [utmp_entry + UTMP_LINE_OFF]
    mov     rsi, r13
    call    str_eq
    test    rax, rax
    jz      .utmp_read_entry

    ; Match found! Copy ut_user to name_buf
    lea     rsi, [utmp_entry + UTMP_USER_OFF]
    mov     rdi, name_buf
    xor     rcx, rcx
.utmp_copy_name:
    cmp     rcx, UT_NAMESIZE - 1
    jge     .utmp_name_done
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .utmp_name_done
    mov     [rdi + rcx], al
    inc     rcx
    jmp     .utmp_copy_name
.utmp_name_done:
    mov     byte [rdi + rcx], 0

    ; Close fd
    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall

    mov     rax, name_buf

    pop     r13
    pop     r12
    pop     rbx
    ret

.utmp_close_fail:
    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall

.utmp_fail:
    xor     rax, rax
    pop     r13
    pop     r12
    pop     rbx
    ret
