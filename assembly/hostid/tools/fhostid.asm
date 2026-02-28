; fhostid.asm — print the numeric identifier for the current host
; GNU-compatible implementation of hostid
;
; Logic:
; 1. Parse args for --help/--version (with prefix matching), reject any other arg
; 2. Try reading 4 bytes from /etc/hostid
; 3. If not available, get hostname via uname(), look up in /etc/hosts
; 4. Apply rol 16 to IP address (matching glibc gethostid behavior)
; 5. Output as 8-char lowercase hex + newline

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write
extern asm_exit
extern asm_write_err
extern asm_strlen
extern asm_strcmp
extern asm_check_flag

global _start

section .data
    str_help: db "Usage: hostid [OPTION]", 10
              db "Print the numeric identifier (in hexadecimal) for the current host.", 10
              db 10
              db "      --help        display this help and exit", 10
              db "      --version     output version information and exit", 10
              db 10
              db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
              db "Full documentation <https://www.gnu.org/software/coreutils/hostid>", 10
              db "or available locally via: info '(coreutils) hostid invocation'", 10
    str_help_len equ $ - str_help

    str_version: db "hostid (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
                 db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
                 db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
                 db "This is free software: you are free to change and redistribute it.", 10
                 db "There is NO WARRANTY, to the extent permitted by law.", 10
                 db 10
                 db "Written by Jim Meyering.", 10
    str_version_len equ $ - str_version

    str_err_prefix:     db "hostid: "
    str_err_prefix_len  equ 8
    str_err_unrec:      db "unrecognized option '"
    str_err_unrec_len   equ 21
    str_err_invalid:    db "invalid option -- '"
    str_err_invalid_len equ 19
    str_err_extra:      db "extra operand '"
    str_err_extra_len   equ 15
    str_err_apost_nl:   db "'", 10
    str_err_apost_nl_len equ 2
    str_try:            db "Try 'hostid --help' for more information.", 10
    str_try_len         equ 42

    str_etc_hostid:  db "/etc/hostid", 0
    str_etc_hosts:   db "/etc/hosts", 0

    hex_chars:       db "0123456789abcdef"

    str_dashdash:    db "--", 0

section .bss
    ; struct utsname: 6 fields of 65 bytes each = 390 bytes
    uname_buf:  resb 390
    hosts_buf:  resb 4096
    hex_output: resb 10         ; "XXXXXXXX\n\0"
    hostid_val: resd 1          ; 4-byte host id from file

section .text

_start:
    ; Get argc/argv from stack
    ; At ELF entry, rsp is 16-byte aligned
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv
    sub     rsp, 8              ; align stack: rsp%16==8 for ABI-correct calls

    ; If argc == 1, no arguments, go to main logic
    cmp     r14, 1
    jle     .run_main

    ; Check argv[1]
    mov     r12, [r15 + 8]      ; argv[1], saved in callee-saved r12

    ; Check for "--" (end of options marker)
    mov     rdi, r12
    lea     rsi, [rel str_dashdash]
    call    asm_strcmp
    test    rax, rax
    jz      .handle_dashdash

    ; Check for --help / --version (with prefix matching)
    mov     rdi, r12
    call    asm_check_flag
    cmp     rax, 1
    je      .do_help
    cmp     rax, 2
    je      .do_version

    ; Not --help or --version: error on any other argument
    mov     rdi, r12
    jmp     .report_error

.handle_dashdash:
    ; "--" found: if argc > 2, next arg is "extra operand"
    cmp     r14, 2
    jle     .run_main
    mov     rdi, [r15 + 16]     ; argv[2]
    jmp     .error_extra_operand

; ── Error reporting ──────────────────────────────────────────
.report_error:
    ; rdi = argument string that caused the error
    cmp     byte [rdi], '-'
    jne     .error_extra_operand
    cmp     byte [rdi + 1], '-'
    je      .error_unrecognized
    cmp     byte [rdi + 1], 0
    je      .error_extra_operand
    jmp     .error_invalid_option

.error_unrecognized:
    ; "hostid: unrecognized option 'ARG'\n"
    mov     r12, rdi            ; save arg
    mov     rdi, STDERR
    lea     rsi, [rel str_err_prefix]
    mov     rdx, str_err_prefix_len
    call    asm_write
    mov     rdi, STDERR
    lea     rsi, [rel str_err_unrec]
    mov     rdx, str_err_unrec_len
    call    asm_write
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, r12
    mov     rdi, STDERR
    call    asm_write
    mov     rdi, STDERR
    lea     rsi, [rel str_err_apost_nl]
    mov     rdx, str_err_apost_nl_len
    call    asm_write
    jmp     .error_try_help

.error_invalid_option:
    ; "hostid: invalid option -- 'C'\n"
    movzx   r12d, byte [rdi + 1]
    mov     rdi, STDERR
    lea     rsi, [rel str_err_prefix]
    mov     rdx, str_err_prefix_len
    call    asm_write
    mov     rdi, STDERR
    lea     rsi, [rel str_err_invalid]
    mov     rdx, str_err_invalid_len
    call    asm_write
    ; Write the single char from stack
    sub     rsp, 16             ; maintain 16-byte alignment
    mov     byte [rsp], r12b
    mov     rdi, STDERR
    mov     rsi, rsp
    mov     rdx, 1
    call    asm_write
    add     rsp, 16
    mov     rdi, STDERR
    lea     rsi, [rel str_err_apost_nl]
    mov     rdx, str_err_apost_nl_len
    call    asm_write
    jmp     .error_try_help

.error_extra_operand:
    ; "hostid: extra operand 'ARG'\n"
    mov     r12, rdi
    mov     rdi, STDERR
    lea     rsi, [rel str_err_prefix]
    mov     rdx, str_err_prefix_len
    call    asm_write
    mov     rdi, STDERR
    lea     rsi, [rel str_err_extra]
    mov     rdx, str_err_extra_len
    call    asm_write
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, r12
    mov     rdi, STDERR
    call    asm_write
    mov     rdi, STDERR
    lea     rsi, [rel str_err_apost_nl]
    mov     rdx, str_err_apost_nl_len
    call    asm_write
    jmp     .error_try_help

.error_try_help:
    mov     rdi, STDERR
    lea     rsi, [rel str_try]
    mov     rdx, str_try_len
    call    asm_write
    mov     rdi, 1
    call    asm_exit

; ── Help and Version ─────────────────────────────────────────
.do_help:
    mov     rdi, STDOUT
    lea     rsi, [rel str_help]
    mov     rdx, str_help_len
    call    asm_write
    xor     rdi, rdi
    call    asm_exit

.do_version:
    mov     rdi, STDOUT
    lea     rsi, [rel str_version]
    mov     rdx, str_version_len
    call    asm_write
    xor     rdi, rdi
    call    asm_exit

; ============================================================
; Main logic: get host ID
; ============================================================
.run_main:
    ; Step 1: Try /etc/hostid
    mov     rax, SYS_OPEN
    lea     rdi, [rel str_etc_hostid]
    xor     rsi, rsi            ; O_RDONLY
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .try_hostname

    ; Read 4 bytes (with EINTR retry)
    mov     r12, rax            ; save fd
.read_hostid_retry:
    mov     rdi, r12
    lea     rsi, [rel hostid_val]
    mov     rdx, 4
    mov     rax, SYS_READ
    syscall
    cmp     rax, -4             ; EINTR?
    je      .read_hostid_retry
    mov     r13, rax            ; save bytes read

    ; Close file
    mov     rdi, r12
    mov     rax, SYS_CLOSE
    syscall

    cmp     r13, 4
    jne     .try_hostname

    ; Got 4 bytes from /etc/hostid — use directly (no rol)
    mov     eax, [rel hostid_val]
    jmp     .format_and_output

; ── Step 2: hostname lookup ──────────────────────────────────
.try_hostname:
    ; Call uname()
    mov     rax, SYS_UNAME
    lea     rdi, [rel uname_buf]
    syscall
    test    rax, rax
    js      .output_zero

    ; nodename is at offset 65 in struct utsname
    lea     r13, [rel uname_buf + 65]

    ; Open /etc/hosts
    mov     rax, SYS_OPEN
    lea     rdi, [rel str_etc_hosts]
    xor     rsi, rsi
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .output_zero

    mov     r12, rax            ; fd

    ; Read /etc/hosts into buffer (with EINTR retry)
.read_hosts_retry:
    mov     rdi, r12
    lea     rsi, [rel hosts_buf]
    mov     rdx, 4095
    mov     rax, SYS_READ
    syscall
    cmp     rax, -4             ; EINTR?
    je      .read_hosts_retry
    mov     r14, rax            ; bytes read

    ; Close file
    mov     rdi, r12
    mov     rax, SYS_CLOSE
    syscall

    cmp     r14, 0
    jle     .output_zero

    ; Null-terminate the buffer
    lea     rbx, [rel hosts_buf]
    mov     byte [rbx + r14], 0

    ; Parse /etc/hosts for our hostname
    ; rbx = buffer, r13 = hostname
    call    .parse_hosts_file
    ; eax = host ID (IP with rol 16), or 0 if not found
    jmp     .format_and_output

.output_zero:
    xor     eax, eax

; ── Format 32-bit value as 8-char hex + newline, write, exit ─
.format_and_output:
    ; eax = 32-bit host ID value
    ; We need to produce "XXXXXXXX\n" (8 lowercase hex chars + newline)
    mov     r8d, eax            ; save the value in r8d
    lea     rdi, [rel hex_output]
    lea     rsi, [rel hex_chars]

    ; Nibble 0 (bits 28-31)
    mov     eax, r8d
    shr     eax, 28
    and     eax, 0xF
    mov     al, [rsi + rax]
    mov     [rdi], al

    ; Nibble 1 (bits 24-27)
    mov     eax, r8d
    shr     eax, 24
    and     eax, 0xF
    mov     al, [rsi + rax]
    mov     [rdi + 1], al

    ; Nibble 2 (bits 20-23)
    mov     eax, r8d
    shr     eax, 20
    and     eax, 0xF
    mov     al, [rsi + rax]
    mov     [rdi + 2], al

    ; Nibble 3 (bits 16-19)
    mov     eax, r8d
    shr     eax, 16
    and     eax, 0xF
    mov     al, [rsi + rax]
    mov     [rdi + 3], al

    ; Nibble 4 (bits 12-15)
    mov     eax, r8d
    shr     eax, 12
    and     eax, 0xF
    mov     al, [rsi + rax]
    mov     [rdi + 4], al

    ; Nibble 5 (bits 8-11)
    mov     eax, r8d
    shr     eax, 8
    and     eax, 0xF
    mov     al, [rsi + rax]
    mov     [rdi + 5], al

    ; Nibble 6 (bits 4-7)
    mov     eax, r8d
    shr     eax, 4
    and     eax, 0xF
    mov     al, [rsi + rax]
    mov     [rdi + 6], al

    ; Nibble 7 (bits 0-3)
    mov     eax, r8d
    and     eax, 0xF
    mov     al, [rsi + rax]
    mov     [rdi + 7], al

    ; Newline
    mov     byte [rdi + 8], 10

    ; Write output
    mov     rdi, STDOUT
    lea     rsi, [rel hex_output]
    mov     rdx, 9
    call    asm_write

    ; Exit 0
    xor     rdi, rdi
    call    asm_exit

; ============================================================
; Parse /etc/hosts file to find hostname
; Input: rbx = buffer start, r13 = hostname to match
; Returns: eax = host ID (IP with rol 16) or 0
; Clobbers: rbx, rcx, rdx, rsi, rdi, r8, r9, r10, r11
; ============================================================
.parse_hosts_file:
    push    r14
    push    r15
    ; rbx = current position in buffer

.ph_next_line:
    ; Skip leading whitespace
.ph_skip_ws:
    cmp     byte [rbx], 0
    je      .ph_not_found
    cmp     byte [rbx], ' '
    je      .ph_skip_ws_inc
    cmp     byte [rbx], 9
    je      .ph_skip_ws_inc
    jmp     .ph_check_line
.ph_skip_ws_inc:
    inc     rbx
    jmp     .ph_skip_ws

.ph_check_line:
    ; Skip comments and empty lines
    cmp     byte [rbx], '#'
    je      .ph_skip_line
    cmp     byte [rbx], 10
    je      .ph_inc_line

    ; Parse IP address at current position
    call    .parse_ip_addr
    test    eax, eax
    jz      .ph_skip_line
    mov     r15d, eax           ; r15d = parsed IP

    ; Skip whitespace after IP
.ph_skip_ws2:
    cmp     byte [rbx], 0
    je      .ph_not_found
    cmp     byte [rbx], ' '
    je      .ph_skip_ws2_inc
    cmp     byte [rbx], 9
    je      .ph_skip_ws2_inc
    jmp     .ph_check_names
.ph_skip_ws2_inc:
    inc     rbx
    jmp     .ph_skip_ws2

    ; Check each hostname on this line
.ph_check_names:
    cmp     byte [rbx], 0
    je      .ph_not_found
    cmp     byte [rbx], 10
    je      .ph_inc_line
    cmp     byte [rbx], '#'
    je      .ph_skip_line

    ; Compare hostname at [rbx] with target at [r13]
    xor     rcx, rcx
.ph_cmp_loop:
    mov     al, [rbx + rcx]
    mov     dl, [r13 + rcx]
    ; Is candidate char a delimiter?
    cmp     al, ' '
    je      .ph_cmp_end
    cmp     al, 9
    je      .ph_cmp_end
    cmp     al, 10
    je      .ph_cmp_end
    cmp     al, 0
    je      .ph_cmp_end
    cmp     al, '#'
    je      .ph_cmp_end
    ; Compare
    cmp     al, dl
    jne     .ph_skip_name
    inc     rcx
    jmp     .ph_cmp_loop

.ph_cmp_end:
    ; Candidate ended. Our hostname must also end here.
    cmp     dl, 0
    jne     .ph_skip_name
    ; Match! Apply rol 16 and return
    mov     eax, r15d
    rol     eax, 16
    pop     r15
    pop     r14
    ret

.ph_skip_name:
    ; Skip to next whitespace or end of line
.ph_skip_name_loop:
    cmp     byte [rbx], 0
    je      .ph_not_found
    cmp     byte [rbx], ' '
    je      .ph_after_name
    cmp     byte [rbx], 9
    je      .ph_after_name
    cmp     byte [rbx], 10
    je      .ph_inc_line
    cmp     byte [rbx], '#'
    je      .ph_skip_line
    inc     rbx
    jmp     .ph_skip_name_loop

.ph_after_name:
    ; Skip whitespace, then check next hostname
    inc     rbx
.ph_after_name_ws:
    cmp     byte [rbx], 0
    je      .ph_not_found
    cmp     byte [rbx], ' '
    je      .ph_after_name_ws_inc
    cmp     byte [rbx], 9
    je      .ph_after_name_ws_inc
    jmp     .ph_check_names
.ph_after_name_ws_inc:
    inc     rbx
    jmp     .ph_after_name_ws

.ph_skip_line:
    cmp     byte [rbx], 0
    je      .ph_not_found
    cmp     byte [rbx], 10
    je      .ph_inc_line
    inc     rbx
    jmp     .ph_skip_line

.ph_inc_line:
    inc     rbx
    jmp     .ph_next_line

.ph_not_found:
    xor     eax, eax
    pop     r15
    pop     r14
    ret

; ============================================================
; Parse IPv4 address from text at [rbx]
; Returns: eax = IP packed into uint32 (octet 0 at bits 0-7, matching memcpy on LE)
; Advances rbx past the address
; Returns 0 on error
; ============================================================
.parse_ip_addr:
    push    r10
    push    r11
    xor     r10d, r10d          ; accumulated result
    xor     r11d, r11d          ; octet counter (0-3)

.pip_octet:
    xor     eax, eax            ; current octet value
    xor     ecx, ecx            ; digit count

.pip_digit:
    movzx   edx, byte [rbx]
    sub     edx, '0'
    cmp     edx, 9
    ja      .pip_octet_done
    imul    eax, 10
    add     eax, edx
    inc     ecx
    inc     rbx
    cmp     ecx, 3
    jle     .pip_digit

.pip_octet_done:
    test    ecx, ecx
    jz      .pip_fail
    cmp     eax, 255
    ja      .pip_fail

    ; Place octet into r10d at byte position r11d
    ; Byte 0 = bits 0-7, byte 1 = bits 8-15, etc. (LE memory layout = network order with memcpy)
    mov     ecx, r11d
    shl     ecx, 3              ; bit offset = octet_num * 8
    shl     eax, cl
    or      r10d, eax

    inc     r11d
    cmp     r11d, 4
    je      .pip_done

    ; Expect a dot separator
    cmp     byte [rbx], '.'
    jne     .pip_fail
    inc     rbx
    jmp     .pip_octet

.pip_done:
    mov     eax, r10d
    pop     r11
    pop     r10
    ret

.pip_fail:
    xor     eax, eax
    pop     r11
    pop     r10
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
