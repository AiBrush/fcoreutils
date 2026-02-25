%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write
extern asm_exit
extern asm_strlen
extern parse_echo_flags

global _start

section .data
    str_space:      db ' '
    str_newline:    db 10

section .bss
    out_buf:    resb BUF_SIZE
    ; Escape expansion buffer for -e mode
    esc_buf:    resb BUF_SIZE

section .text

_start:
    ; Get argc and argv from stack
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Parse flags (-n, -e, -E)
    mov     rdi, r14
    mov     rsi, r15
    call    parse_echo_flags
    ; rax = index of first text arg, edx = flags

    mov     r12, rax            ; r12 = first text arg index
    mov     r13d, edx           ; r13d = flags (bit0=no_newline, bit1=escapes)
    mov     rbp, rax            ; rbp = saved first text arg index (for space logic)

    ; Initialize output buffer
    xor     ebx, ebx            ; rbx = output buffer position

    ; Check if we have any text args
    cmp     r12, r14
    jge     .write_output       ; no text args, go to output

    ; Check if escape interpretation is enabled
    test    r13d, 2
    jnz     .escape_loop

    ; ---- Fast path: no escape interpretation ----
.fast_loop:
    cmp     r12, r14
    jge     .write_output

    ; Add space separator between args (not before first)
    cmp     r12, rbp
    je      .fast_no_space      ; first text arg, no space needed

    ; Bounds check before writing space
    cmp     rbx, BUF_SIZE - 1
    jge     .flush_and_continue_fast
    mov     byte [out_buf + rbx], ' '
    inc     rbx

.fast_no_space:
    ; Get current arg string
    mov     rsi, [r15 + r12 * 8]

    ; Copy arg to buffer
.fast_copy:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .fast_next_arg

    ; Bounds check
    cmp     rbx, BUF_SIZE - 1
    jge     .flush_and_continue_fast_copy

    mov     byte [out_buf + rbx], al
    inc     rbx
    inc     rsi
    jmp     .fast_copy

.fast_next_arg:
    inc     r12
    jmp     .fast_loop

    ; ---- Slow path: escape interpretation ----
.escape_loop:
    cmp     r12, r14
    jge     .write_output

    ; Add space separator between args (not before first)
    cmp     r12, rbp
    je      .esc_no_space       ; first text arg, no space needed

    cmp     rbx, BUF_SIZE - 1
    jge     .flush_and_continue_esc
    mov     byte [out_buf + rbx], ' '
    inc     rbx

.esc_no_space:
    ; Get current arg string
    mov     rsi, [r15 + r12 * 8]

    ; Process escape sequences in this arg
.esc_copy:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .esc_next_arg

    cmp     al, '\'
    je      .handle_escape

    ; Regular char - bounds check and copy
    cmp     rbx, BUF_SIZE - 1
    jge     .flush_and_continue_esc_copy
    mov     byte [out_buf + rbx], al
    inc     rbx
    inc     rsi
    jmp     .esc_copy

.handle_escape:
    ; Look at next char
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
    je      .esc_stop           ; \c = stop all output
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

    ; Unknown escape: output backslash + char literally
    cmp     rbx, BUF_SIZE - 2
    jge     .flush_and_continue_esc_copy
    mov     byte [out_buf + rbx], '\'
    inc     rbx
    mov     byte [out_buf + rbx], al
    inc     rbx
    add     rsi, 2
    jmp     .esc_copy

.trailing_backslash:
    ; Backslash at end of string - output literally
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
    ; \c - stop all output immediately (no trailing newline)
    ; Write what we have and exit
    jmp     .write_and_exit_0

.esc_octal:
    ; \0 followed by up to 3 octal digits
    add     rsi, 2          ; skip \0
    xor     ecx, ecx        ; accumulator
    xor     edx, edx        ; digit count

.octal_digit:
    cmp     edx, 3
    jge     .octal_done
    movzx   eax, byte [rsi]
    sub     al, '0'
    cmp     al, 7
    ja      .octal_done     ; not an octal digit
    shl     ecx, 3
    add     ecx, eax
    inc     rsi
    inc     edx
    jmp     .octal_digit

.octal_done:
    and     ecx, 0xFF       ; clamp to byte
    cmp     rbx, BUF_SIZE - 1
    jge     .flush_and_continue_esc_copy
    mov     byte [out_buf + rbx], cl
    inc     rbx
    jmp     .esc_copy

.esc_hex:
    ; \x followed by up to 2 hex digits
    add     rsi, 2          ; skip \x
    xor     ecx, ecx        ; accumulator
    xor     edx, edx        ; digit count

.hex_digit:
    cmp     edx, 2
    jge     .hex_done
    movzx   eax, byte [rsi]

    ; Check 0-9
    cmp     al, '0'
    jb      .hex_check_no_digits
    cmp     al, '9'
    jbe     .hex_digit_09

    ; Check a-f
    cmp     al, 'a'
    jb      .hex_check_upper
    cmp     al, 'f'
    jbe     .hex_digit_af

    ; Check A-F
.hex_check_upper:
    cmp     al, 'A'
    jb      .hex_check_no_digits
    cmp     al, 'F'
    jbe     .hex_digit_AF

.hex_check_no_digits:
    ; Not a hex digit
    test    edx, edx
    jz      .hex_no_digits  ; no digits found at all
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
    ; \x with no valid hex digits - output \x literally
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

    ; ---- Output ----
.write_output:
    ; Add trailing newline unless -n flag is set
    test    r13d, 1
    jnz     .write_and_exit_0

    cmp     rbx, BUF_SIZE - 1
    jge     .flush_then_newline
    mov     byte [out_buf + rbx], 10
    inc     rbx

.write_and_exit_0:
    ; Write buffer to stdout
    test    rbx, rbx
    jz      .exit_0

    mov     rdi, STDOUT
    lea     rsi, [out_buf]
    mov     rdx, rbx
    call    asm_write

    ; Check for write error
    test    rax, rax
    js      .exit_0         ; silently exit on error (like broken pipe)

.exit_0:
    xor     edi, edi
    call    asm_exit

    ; ---- Flush helper: writes buffer and resets position ----
    ; Preserves: r12-r15, rbp, r13d
    ; Clobbers: rax, rdi, rsi, rdx, rcx, r11
.do_flush:
    mov     rdi, STDOUT
    lea     rsi, [out_buf]
    mov     rdx, rbx
    call    asm_write
    xor     ebx, ebx
    ret

    ; ---- Flush helpers for buffer-full cases ----
.flush_and_continue_fast:
    ; Save rsi (argv entry pointer) before flush
    push    rsi
    call    .do_flush
    pop     rsi
    ; After flushing, add the space that didn't fit
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
    ; After flushing, add the space that didn't fit
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
