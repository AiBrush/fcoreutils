; ============================================================
; fecho_unified.asm — AUTO-GENERATED unified file
; Hand-crafted ELF64 header — allows nasm -f bin (no linker)
; ============================================================
BITS 64
ORG 0x400000

; ── Constants ────────────────────────────────────────────────
%define SYS_WRITE       1
%define SYS_EXIT       60
%define STDOUT          1
%define STDERR          2
%define BUF_SIZE    65536

; ── ELF Header (64 bytes) ───────────────────────────────────
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
dw 64                       ; ELF header size
dw 56                       ; program header entry size
dw 2                        ; 2 program headers
dw 64                       ; section header entry size
dw 0                        ; section header count
dw 0                        ; section name index

; ── Program Header: PT_LOAD (code+data+bss) ─────────────────
phdr:
dd 1                        ; PT_LOAD
dd 7                        ; PF_R | PF_W | PF_X
dq 0                        ; offset
dq $$                       ; virtual address
dq $$                       ; physical address
dq file_size                ; file size
dq file_size + bss_size     ; memory size (includes BSS)
dq 0x200000                 ; alignment

; ── Program Header: PT_GNU_STACK (NX stack) ──────────────────
dd 0x6474e551               ; PT_GNU_STACK
dd 6                        ; PF_R | PF_W (no execute)
dq 0
dq 0
dq 0
dq 0
dq 0
dq 0x10                     ; alignment

; ── Data Section ─────────────────────────────────────────────
str_space:      db ' '
str_newline:    db 10

; ── Code Section ─────────────────────────────────────────────

; ──────────────────────────────────────────────────────────────
; asm_write(rdi=fd, rsi=buf, rdx=len) -> rax
; Retries on EINTR automatically
; ──────────────────────────────────────────────────────────────
asm_write:
.retry:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      .retry
    ret

; ──────────────────────────────────────────────────────────────
; asm_exit(rdi=code) — never returns
; ──────────────────────────────────────────────────────────────
asm_exit:
    mov     rax, SYS_EXIT
    syscall

; ──────────────────────────────────────────────────────────────
; parse_echo_flags(rdi=argc, rsi=argv)
; Returns: rax = index of first non-flag arg, edx = flags byte
;   bit 0 = no_newline (-n), bit 1 = interpret_escapes (-e)
; ──────────────────────────────────────────────────────────────
parse_echo_flags:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, rdi
    mov     r13, rsi
    xor     r14d, r14d
    mov     rbx, 1

.pef_next_arg:
    cmp     rbx, r12
    jge     .pef_done
    mov     rdi, [r13 + rbx * 8]
    cmp     byte [rdi], '-'
    jne     .pef_done
    cmp     byte [rdi + 1], 0
    je      .pef_done
    lea     rsi, [rdi + 1]
    mov     ecx, r14d

.pef_scan_char:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .pef_flag_valid
    cmp     al, 'n'
    je      .pef_set_n
    cmp     al, 'e'
    je      .pef_set_e
    cmp     al, 'E'
    je      .pef_set_E
    jmp     .pef_done

.pef_set_n:
    or      ecx, 1
    inc     rsi
    jmp     .pef_scan_char
.pef_set_e:
    or      ecx, 2
    inc     rsi
    jmp     .pef_scan_char
.pef_set_E:
    and     ecx, ~2
    inc     rsi
    jmp     .pef_scan_char

.pef_flag_valid:
    mov     r14d, ecx
    inc     rbx
    jmp     .pef_next_arg

.pef_done:
    mov     rax, rbx
    mov     edx, r14d
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ──────────────────────────────────────────────────────────────
; _start — main entry point
; ──────────────────────────────────────────────────────────────
_start:
    mov     r14, [rsp]
    lea     r15, [rsp + 8]

    mov     rdi, r14
    mov     rsi, r15
    call    parse_echo_flags

    mov     r12, rax
    mov     r13d, edx
    mov     rbp, rax

    xor     ebx, ebx

    cmp     r12, r14
    jge     .write_output

    test    r13d, 2
    jnz     .escape_loop

; ── Fast path: no escape interpretation ──────────────────────
.fast_loop:
    cmp     r12, r14
    jge     .write_output

    cmp     r12, rbp
    je      .fast_no_space

    cmp     rbx, BUF_SIZE - 1
    jge     .flush_and_continue_fast
    mov     byte [out_buf + rbx], ' '
    inc     rbx

.fast_no_space:
    mov     rsi, [r15 + r12 * 8]

.fast_copy:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .fast_next_arg

    cmp     rbx, BUF_SIZE - 1
    jge     .flush_and_continue_fast_copy

    mov     byte [out_buf + rbx], al
    inc     rbx
    inc     rsi
    jmp     .fast_copy

.fast_next_arg:
    inc     r12
    jmp     .fast_loop

; ── Slow path: escape interpretation ─────────────────────────
.escape_loop:
    cmp     r12, r14
    jge     .write_output

    cmp     r12, rbp
    je      .esc_no_space

    cmp     rbx, BUF_SIZE - 1
    jge     .flush_and_continue_esc
    mov     byte [out_buf + rbx], ' '
    inc     rbx

.esc_no_space:
    mov     rsi, [r15 + r12 * 8]

.esc_copy:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .esc_next_arg

    cmp     al, '\'
    je      .handle_escape

    cmp     rbx, BUF_SIZE - 1
    jge     .flush_and_continue_esc_copy
    mov     byte [out_buf + rbx], al
    inc     rbx
    inc     rsi
    jmp     .esc_copy

.handle_escape:
    movzx   eax, byte [rsi + 1]
    test    al, al
    jz      .trailing_backslash

    cmp     al, '\'
    je      .esc_backslash
    cmp     al, 'a'
    je      .esc_alert
    cmp     al, 'b'
    je      .esc_backspace
    cmp     al, 'c'
    je      .esc_stop
    cmp     al, 'e'
    je      .esc_escape
    cmp     al, 'f'
    je      .esc_formfeed
    cmp     al, 'n'
    je      .esc_newline
    cmp     al, 'r'
    je      .esc_carriage
    cmp     al, 't'
    je      .esc_tab
    cmp     al, 'v'
    je      .esc_vtab
    cmp     al, '0'
    je      .esc_octal
    cmp     al, 'x'
    je      .esc_hex

    ; Unknown escape: output backslash + char
    cmp     rbx, BUF_SIZE - 2
    jge     .flush_and_continue_esc_copy
    mov     byte [out_buf + rbx], '\'
    inc     rbx
    mov     byte [out_buf + rbx], al
    inc     rbx
    add     rsi, 2
    jmp     .esc_copy

.trailing_backslash:
    cmp     rbx, BUF_SIZE - 1
    jge     .flush_and_continue_esc_copy
    mov     byte [out_buf + rbx], '\'
    inc     rbx
    inc     rsi
    jmp     .esc_copy

.esc_backslash:
    mov     cl, '\'
    jmp     .emit_esc_char
.esc_alert:
    mov     cl, 7
    jmp     .emit_esc_char
.esc_backspace:
    mov     cl, 8
    jmp     .emit_esc_char
.esc_escape:
    mov     cl, 27
    jmp     .emit_esc_char
.esc_formfeed:
    mov     cl, 12
    jmp     .emit_esc_char
.esc_newline:
    mov     cl, 10
    jmp     .emit_esc_char
.esc_carriage:
    mov     cl, 13
    jmp     .emit_esc_char
.esc_tab:
    mov     cl, 9
    jmp     .emit_esc_char
.esc_vtab:
    mov     cl, 11
    jmp     .emit_esc_char

.emit_esc_char:
    cmp     rbx, BUF_SIZE - 1
    jge     .flush_and_continue_esc_copy
    mov     byte [out_buf + rbx], cl
    inc     rbx
    add     rsi, 2
    jmp     .esc_copy

.esc_stop:
    jmp     .write_and_exit_0

.esc_octal:
    add     rsi, 2
    xor     ecx, ecx
    xor     edx, edx

.octal_digit:
    cmp     edx, 3
    jge     .octal_done
    movzx   eax, byte [rsi]
    sub     al, '0'
    cmp     al, 7
    ja      .octal_done
    shl     ecx, 3
    add     ecx, eax
    inc     rsi
    inc     edx
    jmp     .octal_digit

.octal_done:
    and     ecx, 0xFF
    cmp     rbx, BUF_SIZE - 1
    jge     .flush_and_continue_esc_copy
    mov     byte [out_buf + rbx], cl
    inc     rbx
    jmp     .esc_copy

.esc_hex:
    add     rsi, 2
    xor     ecx, ecx
    xor     edx, edx

.hex_digit:
    cmp     edx, 2
    jge     .hex_done
    movzx   eax, byte [rsi]

    cmp     al, '0'
    jb      .hex_check_no_digits
    cmp     al, '9'
    jbe     .hex_digit_09
    cmp     al, 'a'
    jb      .hex_check_upper
    cmp     al, 'f'
    jbe     .hex_digit_af
.hex_check_upper:
    cmp     al, 'A'
    jb      .hex_check_no_digits
    cmp     al, 'F'
    jbe     .hex_digit_AF

.hex_check_no_digits:
    test    edx, edx
    jz      .hex_no_digits
    jmp     .hex_done

.hex_digit_09:
    sub     al, '0'
    jmp     .hex_accumulate
.hex_digit_af:
    sub     al, 'a'
    add     al, 10
    jmp     .hex_accumulate
.hex_digit_AF:
    sub     al, 'A'
    add     al, 10
.hex_accumulate:
    shl     ecx, 4
    add     ecx, eax
    inc     rsi
    inc     edx
    jmp     .hex_digit

.hex_no_digits:
    cmp     rbx, BUF_SIZE - 2
    jge     .flush_and_continue_esc_copy
    mov     byte [out_buf + rbx], '\'
    inc     rbx
    mov     byte [out_buf + rbx], 'x'
    inc     rbx
    jmp     .esc_copy

.hex_done:
    and     ecx, 0xFF
    cmp     rbx, BUF_SIZE - 1
    jge     .flush_and_continue_esc_copy
    mov     byte [out_buf + rbx], cl
    inc     rbx
    jmp     .esc_copy

.esc_next_arg:
    inc     r12
    jmp     .escape_loop

; ── Output ───────────────────────────────────────────────────
.write_output:
    test    r13d, 1
    jnz     .write_and_exit_0

    cmp     rbx, BUF_SIZE - 1
    jge     .flush_then_newline
    mov     byte [out_buf + rbx], 10
    inc     rbx

.write_and_exit_0:
    test    rbx, rbx
    jz      .exit_0

    mov     rdi, STDOUT
    lea     rsi, [out_buf]
    mov     rdx, rbx
    call    asm_write

    test    rax, rax
    js      .exit_0

.exit_0:
    xor     edi, edi
    call    asm_exit

; ── Flush helpers ────────────────────────────────────────────
.do_flush:
    mov     rdi, STDOUT
    lea     rsi, [out_buf]
    mov     rdx, rbx
    call    asm_write
    xor     ebx, ebx
    ret

.flush_and_continue_fast:
    push    rsi
    call    .do_flush
    pop     rsi
    mov     byte [out_buf + rbx], ' '
    inc     rbx
    jmp     .fast_no_space

.flush_and_continue_fast_copy:
    push    rsi
    call    .do_flush
    pop     rsi
    jmp     .fast_copy

.flush_and_continue_esc:
    push    rsi
    call    .do_flush
    pop     rsi
    mov     byte [out_buf + rbx], ' '
    inc     rbx
    jmp     .esc_no_space

.flush_and_continue_esc_copy:
    push    rsi
    call    .do_flush
    pop     rsi
    jmp     .esc_copy

.flush_then_newline:
    call    .do_flush
    mov     byte [out_buf], 10
    inc     rbx
    jmp     .write_and_exit_0

; ── End of code ──────────────────────────────────────────────
file_size equ $ - $$

; ── BSS (not in file, allocated in memory) ───────────────────
out_buf equ $$ + file_size
bss_size equ BUF_SIZE
