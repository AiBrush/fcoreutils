; ============================================================
; fnproc_unified.asm — GNU-compatible 'nproc' command
; Builds with: nasm -f bin fnproc_unified.asm -o fnproc
;
; nproc: Print number of available processing units.
; Default: uses sched_getaffinity (affinity-limited count).
; --all:  reads /sys/devices/system/cpu/online for total online CPUs.
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXIT       60
%define SYS_RT_SIGPROCMASK 14
%define SYS_SCHED_GETAFFINITY 204

%define O_RDONLY        0
%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13

; --- ELF Header (64 bytes) ---
ehdr:
    db 0x7f, 'E','L','F'       ; magic
    db 2                        ; 64-bit
    db 1                        ; little endian
    db 1                        ; ELF version
    db 0                        ; OS/ABI
    dq 0                        ; padding
    dw 2                        ; ET_EXEC
    dw 0x3e                     ; x86_64
    dd 1                        ; ELF version
    dq _start                   ; entry point
    dq phdr - $$                ; program header offset
    dq 0                        ; section header offset
    dd 0                        ; flags
    dw 64                       ; ELF header size
    dw 56                       ; program header entry size
    dw 2                        ; 2 program headers
    dw 64                       ; section header entry size
    dw 0                        ; section header count
    dw 0                        ; section name index

; --- Program Header: PT_LOAD (code+data+bss) ---
phdr:
    dd 1                        ; PT_LOAD
    dd 7                        ; PF_R | PF_W | PF_X
    dq 0                        ; offset
    dq $$                       ; virtual address
    dq $$                       ; physical address
    dq file_size                ; file size
    dq file_size + bss_size     ; memory size (includes BSS)
    dq 0x200000                 ; alignment

; --- Program Header: PT_GNU_STACK (NX) ---
    dd 0x6474e551               ; PT_GNU_STACK
    dd 6                        ; PF_R | PF_W (no execute)
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0x10                     ; alignment

; ============================================================
; Code
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

    mov     r14, [rsp]          ; argc (qword)
    lea     r15, [rsp + 8]      ; argv

    ; Flags: r12d bit 0 = --all, r13d = ignore count
    xor     r12d, r12d
    xor     r13d, r13d
    mov     ebx, 1              ; arg index (use ebx, callee-saved)

.parse_opts:
    cmp     ebx, r14d
    jge     .done_opts
    mov     rdi, [r15 + rbx*8]
    cmp     byte [rdi], '-'
    jne     .err_extra_operand
    cmp     byte [rdi + 1], '-'
    jne     .err_invalid_option

    ; Long option
    mov     r9, rdi             ; save arg ptr
    ; --help
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .show_help
    ; --version
    mov     rdi, r9
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .show_version
    ; --all
    mov     rdi, r9
    mov     rsi, str_all_flag
    call    str_eq
    test    eax, eax
    jnz     .set_all
    ; --ignore=N
    mov     rdi, r9
    mov     rsi, str_ignore_prefix
    mov     edx, 9              ; length of "--ignore="
    call    str_prefix_match
    test    eax, eax
    jnz     .set_ignore
    ; Unrecognized option
    jmp     .err_unrecog

.show_help:
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.show_version:
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.set_all:
    or      r12d, 1
    inc     ebx
    jmp     .parse_opts

.set_ignore:
    ; Parse number from --ignore=N
    lea     rdi, [r9 + 9]       ; skip "--ignore="
    call    parse_uint
    mov     r13d, eax
    inc     ebx
    jmp     .parse_opts

.err_extra_operand:
    mov     r9, rdi
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_extra
    mov     edx, str_extra_len
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

.err_invalid_option:
    mov     r9, rdi
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    do_write_err
    lea     rsi, [r9 + 1]
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

.err_unrecog:
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

.done_opts:
    ; Check if --all was requested
    test    r12d, 1
    jnz     .get_all_cpus

    ; ── Default: sched_getaffinity ──
    ; Use stack for cpu mask (128 bytes)
    sub     rsp, 128
    mov     rdi, rsp
    ; Clear the mask buffer
    push    rcx
    mov     ecx, 16
    xor     eax, eax
.clear_mask:
    mov     qword [rdi], rax
    add     rdi, 8
    dec     ecx
    jnz     .clear_mask
    pop     rcx

    mov     eax, SYS_SCHED_GETAFFINITY
    xor     edi, edi            ; pid=0 (current process)
    mov     esi, 128            ; cpusetsize
    mov     rdx, rsp            ; mask buffer on stack
    syscall
    test    rax, rax
    js      .affinity_failed

    ; Count set bits in the mask (rax = bytes returned)
    mov     ecx, eax            ; number of bytes
    xor     ebx, ebx            ; total bit count
    xor     r8d, r8d            ; byte index
.popcount_loop:
    cmp     r8d, ecx
    jge     .popcount_done
    movzx   eax, byte [rsp + r8]
    ; Count bits using Kernighan's method
.kernighan:
    test    al, al
    jz      .next_byte
    inc     ebx
    mov     edx, eax
    dec     edx
    and     eax, edx
    jmp     .kernighan
.next_byte:
    inc     r8d
    jmp     .popcount_loop

.popcount_done:
    add     rsp, 128
    ; ebx = number of available CPUs
    jmp     .apply_ignore

.affinity_failed:
    add     rsp, 128
    mov     ebx, 1              ; fallback to 1
    jmp     .apply_ignore

    ; ── --all: read /sys/devices/system/cpu/online ──
.get_all_cpus:
    ; Open the sysfs file
    mov     eax, SYS_OPEN
    mov     rdi, path_cpu_online
    xor     esi, esi            ; O_RDONLY
    xor     edx, edx
    syscall
    test    rax, rax
    js      .all_fallback_affinity

    ; Read file content into stack buffer
    mov     r8, rax             ; save fd
    sub     rsp, 256
    mov     eax, SYS_READ
    mov     edi, r8d
    mov     rsi, rsp
    mov     edx, 255
    syscall
    push    rax                 ; save bytes read

    ; Close file
    mov     eax, SYS_CLOSE
    mov     edi, r8d
    syscall

    pop     rax                 ; restore bytes read
    test    rax, rax
    jle     .all_read_failed

    ; Null-terminate
    mov     byte [rsp + rax], 0

    ; Parse cpu online string like "0-3" or "0-3,5-7" or "0"
    ; Count total CPUs from the ranges
    mov     rdi, rsp
    call    parse_cpu_range
    mov     ebx, eax            ; total CPU count
    add     rsp, 256

    test    ebx, ebx
    jg      .apply_ignore
    mov     ebx, 1
    jmp     .apply_ignore

.all_read_failed:
    add     rsp, 256
.all_fallback_affinity:
    ; Fallback: use sched_getaffinity even for --all
    sub     rsp, 128
    mov     rdi, rsp
    push    rcx
    mov     ecx, 16
    xor     eax, eax
.clear_mask2:
    mov     qword [rdi], rax
    add     rdi, 8
    dec     ecx
    jnz     .clear_mask2
    pop     rcx

    mov     eax, SYS_SCHED_GETAFFINITY
    xor     edi, edi
    mov     esi, 128
    mov     rdx, rsp
    syscall
    test    rax, rax
    js      .fallback_one

    mov     ecx, eax
    xor     ebx, ebx
    xor     r8d, r8d
.popcount_loop2:
    cmp     r8d, ecx
    jge     .popcount_done2
    movzx   eax, byte [rsp + r8]
.kernighan2:
    test    al, al
    jz      .next_byte2
    inc     ebx
    mov     edx, eax
    dec     edx
    and     eax, edx
    jmp     .kernighan2
.next_byte2:
    inc     r8d
    jmp     .popcount_loop2
.popcount_done2:
    add     rsp, 128
    jmp     .apply_ignore

.fallback_one:
    add     rsp, 128
    mov     ebx, 1

.apply_ignore:
    ; ebx = CPU count, r13d = ignore count
    sub     ebx, r13d
    cmp     ebx, 1
    jge     .output_count
    mov     ebx, 1              ; minimum 1

.output_count:
    ; Convert ebx to string and write to stdout
    ; Use stack for itoa buffer
    sub     rsp, 32
    mov     r8, rsp             ; save stack base for length calc
    lea     rdi, [rsp + 30]     ; end of buffer
    mov     byte [rdi], 10      ; newline at end
    dec     rdi
    mov     eax, ebx
    mov     ecx, 10
.itoa_loop:
    xor     edx, edx
    div     ecx
    add     dl, '0'
    mov     [rdi], dl
    dec     rdi
    test    eax, eax
    jnz     .itoa_loop

    ; rdi points one before the first digit
    inc     rdi
    ; Calculate length: (r8 + 31) - rdi
    lea     rdx, [r8 + 31]
    sub     rdx, rdi            ; length including newline
    mov     rsi, rdi
    mov     edi, STDOUT
    call    do_write
    add     rsp, 32
    xor     edi, edi
    jmp     do_exit

; ============================================================
; parse_cpu_range: parse strings like "0-3" or "0-3,5-7,9"
; Input: rdi = pointer to null-terminated string
; Output: eax = total number of CPUs
; ============================================================
parse_cpu_range:
    push    rbx
    push    r12
    xor     r12d, r12d          ; total count

.pcr_next_range:
    ; Skip whitespace/newlines
    movzx   eax, byte [rdi]
    cmp     al, ' '
    je      .pcr_skip_ws
    cmp     al, 10
    je      .pcr_skip_ws
    cmp     al, 13
    je      .pcr_skip_ws
    jmp     .pcr_check_end
.pcr_skip_ws:
    inc     rdi
    jmp     .pcr_next_range

.pcr_check_end:
    cmp     al, 0
    je      .pcr_done

    ; Parse first number
    call    parse_uint_pcr
    mov     ebx, eax            ; start of range

    ; Check for '-' (range)
    movzx   eax, byte [rdi]
    cmp     al, '-'
    jne     .pcr_single

    ; Parse end of range
    inc     rdi
    call    parse_uint_pcr
    ; eax = end, ebx = start
    sub     eax, ebx
    inc     eax                 ; count = end - start + 1
    add     r12d, eax
    jmp     .pcr_separator

.pcr_single:
    inc     r12d                ; single CPU

.pcr_separator:
    movzx   eax, byte [rdi]
    cmp     al, ','
    jne     .pcr_next_range
    inc     rdi                 ; skip comma
    jmp     .pcr_next_range

.pcr_done:
    mov     eax, r12d
    pop     r12
    pop     rbx
    ret

; Parse unsigned int, advancing rdi past digits
; Returns value in eax
parse_uint_pcr:
    xor     eax, eax
    mov     ecx, 10
.pupc_loop:
    movzx   edx, byte [rdi]
    sub     edx, '0'
    js      .pupc_done
    cmp     edx, 9
    jg      .pupc_done
    imul    eax, ecx
    add     eax, edx
    inc     rdi
    jmp     .pupc_loop
.pupc_done:
    ret

; ============================================================
; Utility functions
; ============================================================
do_write:
    ; edi = fd, rsi = buf, edx = len
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4             ; EINTR
    je      do_write
    ret

do_write_err:
    mov     edi, STDERR
    jmp     do_write

do_exit:
    mov     eax, SYS_EXIT
    syscall

str_len:
    ; Input: rdi = string pointer
    ; Output: eax = length
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     eax
    jmp     .sl_loop
.sl_done:
    ret

str_eq:
    ; Compare two null-terminated strings
    ; Input: rdi, rsi
    ; Output: eax = 1 if equal, 0 if not
    xor     ecx, ecx
.se_loop:
    movzx   eax, byte [rdi + rcx]
    movzx   edx, byte [rsi + rcx]
    cmp     al, dl
    jne     .se_ne
    test    al, al
    jz      .se_eq
    inc     ecx
    jmp     .se_loop
.se_eq:
    mov     eax, 1
    ret
.se_ne:
    xor     eax, eax
    ret

str_prefix_match:
    ; Check if string at rdi starts with rsi (edx bytes)
    ; Output: eax = 1 if match, 0 if not
    xor     ecx, ecx
.sp_loop:
    cmp     ecx, edx
    jge     .sp_match
    movzx   eax, byte [rdi + rcx]
    cmp     al, byte [rsi + rcx]
    jne     .sp_nomatch
    inc     ecx
    jmp     .sp_loop
.sp_match:
    mov     eax, 1
    ret
.sp_nomatch:
    xor     eax, eax
    ret

parse_uint:
    ; Parse unsigned integer from string at rdi
    ; Returns value in eax
    xor     eax, eax
    mov     ecx, 10
.pu_loop:
    movzx   edx, byte [rdi]
    sub     edx, '0'
    js      .pu_done
    cmp     edx, 9
    jg      .pu_done
    imul    eax, ecx
    add     eax, edx
    inc     rdi
    jmp     .pu_loop
.pu_done:
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: nproc [OPTION]...", 10
    db "Print the number of processing units available to the current process,", 10
    db "which may be less than the number of online processors", 10, 10
    db "      --all      print the number of installed processors", 10
    db "      --ignore=N  if possible, exclude N processing units", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/nproc>", 10
    db "or available locally via: info '(coreutils) nproc invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "nproc (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Giuseppe Scrivano.", 10
str_version_len equ $ - str_version

str_prefix:      db "nproc: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_extra:       db "extra operand '"
str_extra_len    equ $ - str_extra
str_sq_nl:       db "'", 10
str_try:         db "Try 'nproc --help' for more information.", 10
str_try_len      equ $ - str_try
; @@DATA_END@@

str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_all_flag:    db "--all", 0
str_ignore_prefix: db "--ignore=", 0

path_cpu_online: db "/sys/devices/system/cpu/online", 0

file_size equ $ - $$

; ── BSS (not in file, allocated in memory) ───────────────────
; No BSS needed — all buffers are on the stack.
bss_base equ $$ + file_size
bss_size equ 0
