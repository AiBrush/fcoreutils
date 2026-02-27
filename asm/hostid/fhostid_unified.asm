; ============================================================
; fhostid_unified.asm — AUTO-GENERATED unified file
; Hand-crafted ELF64 header + all code/data merged
; Build: nasm -f bin fhostid_unified.asm -o fhostid_release
; ============================================================

BITS 64

; ── Syscall numbers ──────────────────────────────────────────
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXIT       60
%define SYS_UNAME      63

; ── File descriptors ─────────────────────────────────────────
%define STDOUT          1
%define STDERR          2

; ── Memory layout ────────────────────────────────────────────
; We place code+data at 0x400000, BSS at 0x800000
%define BASE_ADDR       0x400000
%define BSS_ADDR        0x800000
%define BSS_SIZE        8192

; BSS offsets (manual layout)
%define OFF_UNAME_BUF   0         ; 390 bytes
%define OFF_HOSTS_BUF   400       ; 4096 bytes
%define OFF_HEX_OUTPUT  4496      ; 10 bytes
%define OFF_HOSTID_VAL  4512      ; 4 bytes

ORG BASE_ADDR

; ── ELF Header (64 bytes) ───────────────────────────────────
ehdr:
    db 0x7F, 'E', 'L', 'F'     ; magic
    db 2                         ; 64-bit
    db 1                         ; little endian
    db 1                         ; ELF version
    db 0                         ; OS/ABI: System V
    dq 0                         ; padding
    dw 2                         ; ET_EXEC
    dw 0x3E                      ; x86_64
    dd 1                         ; ELF version
    dq _start                    ; entry point
    dq phdr - $$                 ; program header offset
    dq 0                         ; section header offset (none)
    dd 0                         ; flags
    dw 64                        ; ELF header size
    dw 56                        ; program header entry size
    dw 3                         ; 3 program headers (code, bss, gnu_stack)
    dw 64                        ; section header entry size
    dw 0                         ; section header count
    dw 0                         ; section name index

; ── Program Headers ──────────────────────────────────────────
; PT_LOAD: code + data (RX)
phdr:
    dd 1                         ; PT_LOAD
    dd 5                         ; PF_R | PF_X
    dq 0                         ; offset in file
    dq BASE_ADDR                 ; virtual address
    dq BASE_ADDR                 ; physical address
    dq file_size                 ; file size
    dq file_size                 ; memory size
    dq 0x200000                  ; alignment

; PT_LOAD: BSS (RW)
phdr_bss:
    dd 1                         ; PT_LOAD
    dd 6                         ; PF_R | PF_W
    dq 0                         ; offset (0 since it's zero-fill)
    dq BSS_ADDR                  ; virtual address
    dq BSS_ADDR                  ; physical address
    dq 0                         ; file size (0 = zero-filled)
    dq BSS_SIZE                  ; memory size
    dq 0x200000                  ; alignment

; PT_GNU_STACK: non-executable stack
phdr_stack:
    dd 0x6474E551                ; PT_GNU_STACK
    dd 6                         ; PF_R | PF_W (no PF_X = non-executable)
    dq 0                         ; offset
    dq 0                         ; virtual address
    dq 0                         ; physical address
    dq 0                         ; file size
    dq 0                         ; memory size
    dq 0x10                      ; alignment

; ── Data Section ─────────────────────────────────────────────
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
str_err_extra:      db "extra operand ", 0xE2, 0x80, 0x98
str_err_extra_len   equ 17
str_err_apost_nl:   db 0xE2, 0x80, 0x99, 10
str_err_apost_nl_len equ 4
str_err_apost_ascii:   db 0x27, 10
str_err_apost_ascii_len equ 2
str_try:            db "Try 'hostid --help' for more information.", 10
str_try_len         equ 42

str_etc_hostid:  db "/etc/hostid", 0
str_etc_hosts:   db "/etc/hosts", 0
hex_chars:       db "0123456789abcdef"
str_dashdash:    db "--", 0
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0

; ── Code Section ─────────────────────────────────────────────

; ── Library: asm_write (with EINTR retry and partial write handling) ──
asm_write:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi            ; fd
    mov     r12, rsi            ; buf
    mov     r13, rdx            ; remaining len
.aw_retry:
    mov     rax, SYS_WRITE
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    syscall
    cmp     rax, -4             ; -EINTR?
    je      .aw_retry
    test    rax, rax
    js      .aw_done            ; error, return it
    add     r12, rax            ; advance buffer
    sub     r13, rax            ; decrease remaining
    jnz     .aw_retry           ; partial write, retry
    mov     rax, r12            ; return total bytes written
.aw_done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── Library: asm_write_err ───────────────────────────────────
asm_write_err:
    mov     rdi, STDERR
    jmp     asm_write

; ── Library: asm_exit ────────────────────────────────────────
asm_exit:
    mov     rax, SYS_EXIT
    syscall

; ── Library: asm_strlen ──────────────────────────────────────
asm_strlen:
    xor     rax, rax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; ── Library: asm_strcmp ───────────────────────────────────────
asm_strcmp:
    xor     rcx, rcx
.sc_loop:
    mov     al, [rdi + rcx]
    mov     dl, [rsi + rcx]
    cmp     al, dl
    jne     .sc_ne
    test    al, al
    jz      .sc_eq
    inc     rcx
    jmp     .sc_loop
.sc_eq:
    xor     rax, rax
    ret
.sc_ne:
    movzx   rax, al
    movzx   rdx, dl
    sub     rax, rdx
    ret

; ── Library: prefix_match ────────────────────────────────────
; prefix_match(rdi=input, rsi=full_option) -> rax: 1=match, 0=no match
; Input must be a prefix of full_option (at least 3 chars: '--' + first char)
prefix_match:
    cmp     byte [rdi], '-'
    jne     .pm_no
    cmp     byte [rdi + 1], '-'
    jne     .pm_no
    cmp     byte [rdi + 2], 0
    je      .pm_no              ; bare "--" is not a prefix match
    xor     rcx, rcx
.pm_loop:
    mov     al, [rdi + rcx]
    test    al, al
    jz      .pm_yes             ; input ended, it was a prefix
    cmp     al, [rsi + rcx]
    jne     .pm_no              ; mismatch
    inc     rcx
    jmp     .pm_loop
.pm_yes:
    mov     rax, 1
    ret
.pm_no:
    xor     rax, rax
    ret

; ── Library: asm_check_flag (with prefix matching) ───────────
asm_check_flag:
    push    rbx
    mov     rbx, rdi
    ; Try prefix match against --help
    lea     rsi, [rel str_help_flag]
    call    prefix_match
    test    rax, rax
    jnz     .cf_help
    ; Try prefix match against --version
    mov     rdi, rbx
    lea     rsi, [rel str_version_flag]
    call    prefix_match
    test    rax, rax
    jnz     .cf_version
    xor     rax, rax
    pop     rbx
    ret
.cf_help:
    mov     rax, 1
    pop     rbx
    ret
.cf_version:
    mov     rax, 2
    pop     rbx
    ret

; ── Entry Point ──────────────────────────────────────────────
_start:
    mov     r14, [rsp]
    lea     r15, [rsp + 8]
    sub     rsp, 8              ; align stack: rsp%16==8 for ABI-correct calls

    cmp     r14, 1
    jle     .run_main

    mov     r12, [r15 + 8]      ; argv[1], saved in callee-saved r12

    ; Check for "--"
    mov     rdi, r12
    lea     rsi, [rel str_dashdash]
    call    asm_strcmp
    test    rax, rax
    jz      .handle_dashdash

    ; Check --help / --version (with prefix matching)
    mov     rdi, r12
    call    asm_check_flag
    cmp     rax, 1
    je      .do_help
    cmp     rax, 2
    je      .do_version

    mov     rdi, r12
    jmp     .report_error

.handle_dashdash:
    cmp     r14, 2
    jle     .run_main
    mov     rdi, [r15 + 16]
    jmp     .error_extra_operand

; ── Error reporting ──────────────────────────────────────────
.report_error:
    cmp     byte [rdi], '-'
    jne     .error_extra_operand
    cmp     byte [rdi + 1], '-'
    je      .error_unrecognized
    cmp     byte [rdi + 1], 0
    je      .error_extra_operand
    jmp     .error_invalid_option

.error_unrecognized:
    mov     r12, rdi
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
    lea     rsi, [rel str_err_apost_ascii]
    mov     rdx, str_err_apost_ascii_len
    call    asm_write
    jmp     .error_try_help

.error_invalid_option:
    movzx   r12d, byte [rdi + 1]
    mov     rdi, STDERR
    lea     rsi, [rel str_err_prefix]
    mov     rdx, str_err_prefix_len
    call    asm_write
    mov     rdi, STDERR
    lea     rsi, [rel str_err_invalid]
    mov     rdx, str_err_invalid_len
    call    asm_write
    sub     rsp, 16             ; maintain alignment
    mov     byte [rsp], r12b
    mov     rdi, STDERR
    mov     rsi, rsp
    mov     rdx, 1
    call    asm_write
    add     rsp, 16
    mov     rdi, STDERR
    lea     rsi, [rel str_err_apost_ascii]
    mov     rdx, str_err_apost_ascii_len
    call    asm_write
    jmp     .error_try_help

.error_extra_operand:
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

; ── Main logic ───────────────────────────────────────────────
.run_main:
    ; Try /etc/hostid
    mov     rax, SYS_OPEN
    lea     rdi, [rel str_etc_hostid]
    xor     rsi, rsi
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .try_hostname

    mov     r12, rax
.read_hostid_retry:
    mov     rdi, r12
    lea     rsi, [BSS_ADDR + OFF_HOSTID_VAL]
    mov     rdx, 4
    mov     rax, SYS_READ
    syscall
    cmp     rax, -4             ; EINTR?
    je      .read_hostid_retry
    mov     r13, rax

    mov     rdi, r12
    mov     rax, SYS_CLOSE
    syscall

    cmp     r13, 4
    jne     .try_hostname

    mov     eax, [BSS_ADDR + OFF_HOSTID_VAL]
    jmp     .format_and_output

.try_hostname:
    mov     rax, SYS_UNAME
    lea     rdi, [BSS_ADDR + OFF_UNAME_BUF]
    syscall
    test    rax, rax
    js      .output_zero

    lea     r13, [BSS_ADDR + OFF_UNAME_BUF + 65]

    mov     rax, SYS_OPEN
    lea     rdi, [rel str_etc_hosts]
    xor     rsi, rsi
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .output_zero

    mov     r12, rax

.read_hosts_retry:
    mov     rdi, r12
    lea     rsi, [BSS_ADDR + OFF_HOSTS_BUF]
    mov     rdx, 4095
    mov     rax, SYS_READ
    syscall
    cmp     rax, -4             ; EINTR?
    je      .read_hosts_retry
    mov     r14, rax

    mov     rdi, r12
    mov     rax, SYS_CLOSE
    syscall

    cmp     r14, 0
    jle     .output_zero

    lea     rbx, [BSS_ADDR + OFF_HOSTS_BUF]
    mov     byte [rbx + r14], 0

    call    .parse_hosts_file
    jmp     .format_and_output

.output_zero:
    xor     eax, eax

.format_and_output:
    mov     r8d, eax
    lea     rdi, [BSS_ADDR + OFF_HEX_OUTPUT]
    lea     rsi, [rel hex_chars]

    mov     eax, r8d
    shr     eax, 28
    and     eax, 0xF
    mov     al, [rsi + rax]
    mov     [rdi], al

    mov     eax, r8d
    shr     eax, 24
    and     eax, 0xF
    mov     al, [rsi + rax]
    mov     [rdi + 1], al

    mov     eax, r8d
    shr     eax, 20
    and     eax, 0xF
    mov     al, [rsi + rax]
    mov     [rdi + 2], al

    mov     eax, r8d
    shr     eax, 16
    and     eax, 0xF
    mov     al, [rsi + rax]
    mov     [rdi + 3], al

    mov     eax, r8d
    shr     eax, 12
    and     eax, 0xF
    mov     al, [rsi + rax]
    mov     [rdi + 4], al

    mov     eax, r8d
    shr     eax, 8
    and     eax, 0xF
    mov     al, [rsi + rax]
    mov     [rdi + 5], al

    mov     eax, r8d
    shr     eax, 4
    and     eax, 0xF
    mov     al, [rsi + rax]
    mov     [rdi + 6], al

    mov     eax, r8d
    and     eax, 0xF
    mov     al, [rsi + rax]
    mov     [rdi + 7], al

    mov     byte [rdi + 8], 10

    mov     rdi, STDOUT
    lea     rsi, [BSS_ADDR + OFF_HEX_OUTPUT]
    mov     rdx, 9
    call    asm_write

    xor     rdi, rdi
    call    asm_exit

; ── /etc/hosts parser ────────────────────────────────────────
.parse_hosts_file:
    push    r14
    push    r15

.ph_next_line:
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
    cmp     byte [rbx], '#'
    je      .ph_skip_line
    cmp     byte [rbx], 10
    je      .ph_inc_line

    call    .parse_ip_addr
    test    eax, eax
    jz      .ph_skip_line
    mov     r15d, eax

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

.ph_check_names:
    cmp     byte [rbx], 0
    je      .ph_not_found
    cmp     byte [rbx], 10
    je      .ph_inc_line
    cmp     byte [rbx], '#'
    je      .ph_skip_line

    xor     rcx, rcx
.ph_cmp_loop:
    mov     al, [rbx + rcx]
    mov     dl, [r13 + rcx]
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
    cmp     al, dl
    jne     .ph_skip_name
    inc     rcx
    jmp     .ph_cmp_loop

.ph_cmp_end:
    cmp     dl, 0
    jne     .ph_skip_name
    mov     eax, r15d
    rol     eax, 16
    pop     r15
    pop     r14
    ret

.ph_skip_name:
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

; ── IP address parser ────────────────────────────────────────
.parse_ip_addr:
    push    r10
    push    r11
    xor     r10d, r10d
    xor     r11d, r11d

.pip_octet:
    xor     eax, eax
    xor     ecx, ecx

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

    mov     ecx, r11d
    shl     ecx, 3
    shl     eax, cl
    or      r10d, eax

    inc     r11d
    cmp     r11d, 4
    je      .pip_done

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

; ── File size marker ─────────────────────────────────────────
file_size equ $ - $$
