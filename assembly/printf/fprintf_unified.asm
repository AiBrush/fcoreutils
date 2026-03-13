; ============================================================
; fprintf_unified.asm — GNU-compatible 'printf' command
; Builds with: nasm -f bin fprintf_unified.asm -o fprintf
;
; printf: Format and print data.
;
; Register allocation:
;   r14d = argc, r15 = argv
;   r12  = format string pointer
;   r13d = current argument index (for format args)
;   ebx  = scratch / flags
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE           1
%define SYS_EXIT            60
%define SYS_RT_SIGPROCMASK  14

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13

; BSS layout: 0x500000
%define BSS_ADDR       0x500000
%define BSS_SIZE       16384
%define OUT_BUF        BSS_ADDR                ; 8192 bytes
%define NUM_BUF        (BSS_ADDR + 8192)       ; 128 bytes
%define OUT_POS        (BSS_ADDR + 8320)       ; 8 bytes
%define FMT_SPEC       (BSS_ADDR + 8328)       ; 64 bytes - format spec buffer

; --- ELF Header (64 bytes) ---
ehdr:
    db 0x7f, 'E','L','F'
    db 2, 1, 1, 0
    dq 0
    dw 2, 0x3e
    dd 1
    dq _start
    dq phdr - $$
    dq 0
    dd 0
    dw 64, 56, 3, 64, 0, 0

; --- Program Headers ---
phdr:
    ; PT_LOAD: code + data (R+X)
    dd 1, 5
    dq 0, $$, $$, file_size, file_size, 0x200000

    ; PT_LOAD: BSS (R+W)
    dd 1, 6
    dq 0, BSS_ADDR, BSS_ADDR, 0, BSS_SIZE, 0x200000

    ; PT_GNU_STACK (NX)
    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 0x10

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

    ; Save argc/argv
    mov     r14d, [rsp]
    lea     r15, [rsp + 8]

    ; Check argc
    cmp     r14d, 2
    jl      .err_missing_operand

    ; Check for --help and --version
    mov     rdi, [r15 + 8]      ; argv[1]
    push    rdi
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    pop     rdi
    jnz     .show_help
    push    rdi
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    pop     rdi
    jnz     .show_version

    ; argv[1] is the format string
    mov     r12, [r15 + 8]
    mov     r13d, 2              ; first data arg index

    ; Initialize output buffer
    mov     qword [OUT_POS], 0

    ; Process format string (may repeat if more args than specifiers)
.format_loop:
    mov     rdi, r12             ; reset to start of format

.process_char:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .format_done_check
    cmp     al, '%'
    je      .handle_percent
    cmp     al, '\'
    je      .handle_escape
    ; Regular character
    push    rdi
    call    buf_putc
    pop     rdi
    inc     rdi
    jmp     .process_char

.handle_escape:
    inc     rdi
    movzx   eax, byte [rdi]
    test    al, al
    jz      .format_done_check
    cmp     al, '\'
    je      .esc_bslash
    cmp     al, 'n'
    je      .esc_nl
    cmp     al, 't'
    je      .esc_tab
    cmp     al, 'r'
    je      .esc_cr
    cmp     al, 'a'
    je      .esc_bell
    cmp     al, 'b'
    je      .esc_bs
    cmp     al, 'f'
    je      .esc_ff
    cmp     al, 'v'
    je      .esc_vt
    cmp     al, 'c'
    je      .esc_stop          ; \c stops output
    cmp     al, '0'
    je      .esc_octal
    cmp     al, 'x'
    je      .esc_hex
    ; Unknown escape: output backslash + char
    push    rdi
    mov     al, '\'
    call    buf_putc
    pop     rdi
    movzx   eax, byte [rdi]
    push    rdi
    call    buf_putc
    pop     rdi
    inc     rdi
    jmp     .process_char

.esc_bslash:
    push    rdi
    mov     al, '\'
    call    buf_putc
    pop     rdi
    inc     rdi
    jmp     .process_char

.esc_nl:
    push    rdi
    mov     al, 10
    call    buf_putc
    pop     rdi
    inc     rdi
    jmp     .process_char

.esc_tab:
    push    rdi
    mov     al, 9
    call    buf_putc
    pop     rdi
    inc     rdi
    jmp     .process_char

.esc_cr:
    push    rdi
    mov     al, 13
    call    buf_putc
    pop     rdi
    inc     rdi
    jmp     .process_char

.esc_bell:
    push    rdi
    mov     al, 7
    call    buf_putc
    pop     rdi
    inc     rdi
    jmp     .process_char

.esc_bs:
    push    rdi
    mov     al, 8
    call    buf_putc
    pop     rdi
    inc     rdi
    jmp     .process_char

.esc_ff:
    push    rdi
    mov     al, 12
    call    buf_putc
    pop     rdi
    inc     rdi
    jmp     .process_char

.esc_vt:
    push    rdi
    mov     al, 11
    call    buf_putc
    pop     rdi
    inc     rdi
    jmp     .process_char

.esc_stop:
    ; \c: flush and exit
    call    buf_flush
    xor     edi, edi
    jmp     do_exit

.esc_octal:
    ; \0NNN: parse up to 3 octal digits after the 0
    inc     rdi                 ; skip '0'
    xor     ecx, ecx            ; accumulator
    xor     r8d, r8d            ; digit count
.esc_oct_loop:
    cmp     r8d, 3
    jge     .esc_oct_done
    movzx   eax, byte [rdi]
    sub     al, '0'
    cmp     al, 7
    ja      .esc_oct_done
    shl     ecx, 3
    add     ecx, eax
    inc     rdi
    inc     r8d
    jmp     .esc_oct_loop
.esc_oct_done:
    push    rdi
    mov     al, cl
    call    buf_putc
    pop     rdi
    jmp     .process_char

.esc_hex:
    ; \xHH: parse up to 2 hex digits
    inc     rdi                 ; skip 'x'
    xor     ecx, ecx
    xor     r8d, r8d
.esc_hex_loop:
    cmp     r8d, 2
    jge     .esc_hex_done
    movzx   eax, byte [rdi]
    cmp     al, '0'
    jl      .esc_hex_done
    cmp     al, '9'
    jle     .esc_hex_digit
    cmp     al, 'a'
    jl      .esc_hex_try_upper
    cmp     al, 'f'
    jg      .esc_hex_done
    sub     al, ('a' - 10)
    jmp     .esc_hex_acc
.esc_hex_try_upper:
    cmp     al, 'A'
    jl      .esc_hex_done
    cmp     al, 'F'
    jg      .esc_hex_done
    sub     al, ('A' - 10)
    jmp     .esc_hex_acc
.esc_hex_digit:
    sub     al, '0'
.esc_hex_acc:
    shl     ecx, 4
    add     ecx, eax
    inc     rdi
    inc     r8d
    jmp     .esc_hex_loop
.esc_hex_done:
    push    rdi
    mov     al, cl
    call    buf_putc
    pop     rdi
    jmp     .process_char

; ---- Format specifier handling ----
.handle_percent:
    inc     rdi
    movzx   eax, byte [rdi]
    cmp     al, '%'
    je      .pct_literal
    cmp     al, 0
    je      .format_done_check

    ; Save format pointer, skip flags/width/precision
    mov     r8, rdi             ; save start after %

    ; Skip flags: -, +, space, 0, #
.skip_flags:
    movzx   eax, byte [rdi]
    cmp     al, '-'
    je      .skip_flag_next
    cmp     al, '+'
    je      .skip_flag_next
    cmp     al, ' '
    je      .skip_flag_next
    cmp     al, '0'
    je      .skip_flag_next
    cmp     al, '#'
    je      .skip_flag_next
    jmp     .skip_width
.skip_flag_next:
    inc     rdi
    jmp     .skip_flags

    ; Skip width (digits or *)
.skip_width:
    movzx   eax, byte [rdi]
    cmp     al, '*'
    je      .skip_width_star
    cmp     al, '0'
    jl      .check_precision
    cmp     al, '9'
    jg      .check_precision
    inc     rdi
    jmp     .skip_width
.skip_width_star:
    inc     rdi

.check_precision:
    cmp     byte [rdi], '.'
    jne     .got_conversion
    inc     rdi
    ; Skip precision digits or *
.skip_prec:
    movzx   eax, byte [rdi]
    cmp     al, '*'
    je      .skip_prec_star
    cmp     al, '0'
    jl      .got_conversion
    cmp     al, '9'
    jg      .got_conversion
    inc     rdi
    jmp     .skip_prec
.skip_prec_star:
    inc     rdi

.got_conversion:
    ; rdi points at conversion char
    movzx   eax, byte [rdi]
    cmp     al, 's'
    je      .conv_s
    cmp     al, 'd'
    je      .conv_d
    cmp     al, 'i'
    je      .conv_d
    cmp     al, 'u'
    je      .conv_u
    cmp     al, 'o'
    je      .conv_o
    cmp     al, 'x'
    je      .conv_x
    cmp     al, 'X'
    je      .conv_X
    cmp     al, 'c'
    je      .conv_c
    cmp     al, 'f'
    je      .conv_f_stub
    cmp     al, 'e'
    je      .conv_f_stub
    cmp     al, 'g'
    je      .conv_f_stub
    ; Unknown conversion: output literally
    push    rdi
    mov     al, '%'
    call    buf_putc
    pop     rdi
    jmp     .process_char

.pct_literal:
    push    rdi
    mov     al, '%'
    call    buf_putc
    pop     rdi
    inc     rdi
    jmp     .process_char

; ---- %s: string ----
.conv_s:
    push    rdi
    ; Get next argument (or empty string if exhausted)
    cmp     r13d, r14d
    jge     .conv_s_empty
    mov     rsi, [r15 + r13*8]
    inc     r13d
    ; Write the string
    mov     rdi, rsi
    push    rsi
    call    str_len
    pop     rsi
    mov     edx, eax
    call    buf_write_n
    pop     rdi
    inc     rdi
    jmp     .process_char

.conv_s_empty:
    ; No more args - output nothing
    pop     rdi
    inc     rdi
    jmp     .process_char

; ---- %d / %i: signed decimal ----
.conv_d:
    push    rdi
    call    get_next_int_arg
    ; rax = signed value
    test    rax, rax
    jns     .conv_d_pos
    push    rax
    mov     al, '-'
    call    buf_putc
    pop     rax
    neg     rax
.conv_d_pos:
    call    format_and_write_u64
    pop     rdi
    inc     rdi
    jmp     .process_char

; ---- %u: unsigned decimal ----
.conv_u:
    push    rdi
    call    get_next_int_arg
    call    format_and_write_u64
    pop     rdi
    inc     rdi
    jmp     .process_char

; ---- %o: octal ----
.conv_o:
    push    rdi
    call    get_next_int_arg
    call    format_and_write_octal
    pop     rdi
    inc     rdi
    jmp     .process_char

; ---- %x: lowercase hex ----
.conv_x:
    push    rdi
    call    get_next_int_arg
    mov     ecx, 0              ; lowercase flag
    call    format_and_write_hex
    pop     rdi
    inc     rdi
    jmp     .process_char

; ---- %X: uppercase hex ----
.conv_X:
    push    rdi
    call    get_next_int_arg
    mov     ecx, 1              ; uppercase flag
    call    format_and_write_hex
    pop     rdi
    inc     rdi
    jmp     .process_char

; ---- %c: character ----
.conv_c:
    push    rdi
    cmp     r13d, r14d
    jge     .conv_c_empty
    mov     rsi, [r15 + r13*8]
    inc     r13d
    movzx   eax, byte [rsi]
    call    buf_putc
.conv_c_empty:
    pop     rdi
    inc     rdi
    jmp     .process_char

; ---- %f/%e/%g stub: just output "0.000000" or arg as string ----
.conv_f_stub:
    push    rdi
    cmp     r13d, r14d
    jge     .conv_f_default
    mov     rsi, [r15 + r13*8]
    inc     r13d
    ; Try to parse as integer + print with .000000
    mov     rdi, rsi
    call    parse_int
    test    rax, rax
    jns     .conv_f_pos
    push    rax
    mov     al, '-'
    call    buf_putc
    pop     rax
    neg     rax
.conv_f_pos:
    call    format_and_write_u64
    mov     rsi, str_dotzeroes
    mov     edx, 7
    call    buf_write_n
    pop     rdi
    inc     rdi
    jmp     .process_char

.conv_f_default:
    mov     rsi, str_fzero
    mov     edx, str_fzero_len
    call    buf_write_n
    pop     rdi
    inc     rdi
    jmp     .process_char

; ---- End of format string ----
.format_done_check:
    ; If there are still remaining args, re-process format
    cmp     r13d, r14d
    jl      .format_loop

    ; Flush and exit
    call    buf_flush
    xor     edi, edi
    jmp     do_exit

; ============================================================
; Argument parsing helpers
; ============================================================

; get_next_int_arg: get next argv argument as integer
; Returns: rax = parsed value
get_next_int_arg:
    cmp     r13d, r14d
    jge     .gnia_zero
    mov     rdi, [r15 + r13*8]
    inc     r13d

    ; Check for leading ' or " (character value)
    movzx   eax, byte [rdi]
    cmp     al, "'"
    je      .gnia_charval
    cmp     al, '"'
    je      .gnia_charval

    call    parse_int
    ret

.gnia_charval:
    movzx   eax, byte [rdi + 1]
    ret

.gnia_zero:
    xor     eax, eax
    ret

; parse_int: parse NUL-terminated decimal string
; Input: rdi = string, Returns: rax = value (signed)
parse_int:
    xor     rax, rax
    xor     ecx, ecx            ; sign: 0=positive, 1=negative
    movzx   edx, byte [rdi]

    ; Handle optional sign
    cmp     dl, '-'
    je      .pi_neg
    cmp     dl, '+'
    je      .pi_pos
    jmp     .pi_loop

.pi_neg:
    mov     ecx, 1
    inc     rdi
    jmp     .pi_loop

.pi_pos:
    inc     rdi

.pi_loop:
    movzx   edx, byte [rdi]
    sub     dl, '0'
    cmp     dl, 9
    ja      .pi_done
    imul    rax, 10
    movzx   edx, byte [rdi]
    sub     dl, '0'
    add     rax, rdx
    inc     rdi
    jmp     .pi_loop

.pi_done:
    test    ecx, ecx
    jz      .pi_ret
    neg     rax
.pi_ret:
    ret

; ============================================================
; Output formatting
; ============================================================

; format_and_write_u64: format rax as unsigned decimal and write
format_and_write_u64:
    lea     rcx, [NUM_BUF + 63]
    mov     byte [rcx], 0
    mov     r8d, 10
    test    rax, rax
    jnz     .fwu_loop
    dec     rcx
    mov     byte [rcx], '0'
    jmp     .fwu_write
.fwu_loop:
    test    rax, rax
    jz      .fwu_write
    xor     edx, edx
    div     r8
    add     dl, '0'
    dec     rcx
    mov     byte [rcx], dl
    jmp     .fwu_loop
.fwu_write:
    mov     rsi, rcx
    lea     edx, [NUM_BUF + 63]
    sub     edx, ecx
    call    buf_write_n
    ret

; format_and_write_octal: format rax as octal and write
format_and_write_octal:
    lea     rcx, [NUM_BUF + 63]
    mov     byte [rcx], 0
    test    rax, rax
    jnz     .fwo_loop
    dec     rcx
    mov     byte [rcx], '0'
    jmp     .fwo_write
.fwo_loop:
    test    rax, rax
    jz      .fwo_write
    mov     edx, eax
    and     edx, 7
    add     dl, '0'
    dec     rcx
    mov     byte [rcx], dl
    shr     rax, 3
    jmp     .fwo_loop
.fwo_write:
    mov     rsi, rcx
    lea     edx, [NUM_BUF + 63]
    sub     edx, ecx
    call    buf_write_n
    ret

; format_and_write_hex: format rax as hex and write
; ecx = 0 for lowercase, 1 for uppercase
format_and_write_hex:
    push    rcx                 ; save case flag
    lea     r9, [NUM_BUF + 63]
    mov     byte [r9], 0
    test    rax, rax
    jnz     .fwh_loop
    dec     r9
    mov     byte [r9], '0'
    jmp     .fwh_write
.fwh_loop:
    test    rax, rax
    jz      .fwh_write
    mov     edx, eax
    and     edx, 0xF
    cmp     edx, 10
    jl      .fwh_digit
    pop     rcx                 ; case flag
    push    rcx
    test    ecx, ecx
    jnz     .fwh_upper
    add     dl, ('a' - 10)
    jmp     .fwh_store
.fwh_upper:
    add     dl, ('A' - 10)
    jmp     .fwh_store
.fwh_digit:
    add     dl, '0'
.fwh_store:
    dec     r9
    mov     byte [r9], dl
    shr     rax, 4
    jmp     .fwh_loop
.fwh_write:
    pop     rcx                 ; clean stack
    mov     rsi, r9
    lea     edx, [NUM_BUF + 63]
    sub     rdx, r9
    call    buf_write_n
    ret

; ============================================================
; Output buffer routines
; ============================================================

; buf_putc: write single char (al) to buffer
buf_putc:
    push    rdi
    mov     rcx, [OUT_POS]
    mov     byte [OUT_BUF + rcx], al
    inc     rcx
    mov     [OUT_POS], rcx
    cmp     ecx, 8000
    jl      .bpc_done
    call    buf_flush
.bpc_done:
    pop     rdi
    ret

; buf_write_n: write edx bytes from rsi to buffer
buf_write_n:
    push    rdi
    push    r8
    mov     rcx, [OUT_POS]
    xor     eax, eax
.bwn_loop:
    cmp     eax, edx
    jge     .bwn_done
    movzx   r8d, byte [rsi + rax]
    mov     byte [OUT_BUF + rcx], r8b
    inc     rcx
    inc     eax
    cmp     ecx, 8000
    jl      .bwn_loop
    mov     [OUT_POS], rcx
    push    rsi
    push    rdx
    push    rax
    call    buf_flush
    pop     rax
    pop     rdx
    pop     rsi
    xor     ecx, ecx
    jmp     .bwn_loop
.bwn_done:
    mov     [OUT_POS], rcx
    pop     r8
    pop     rdi
    ret

buf_flush:
    mov     rcx, [OUT_POS]
    test    rcx, rcx
    jz      .bf_done
    mov     edi, STDOUT
    mov     rsi, OUT_BUF
    mov     edx, ecx
    call    do_write
    mov     qword [OUT_POS], 0
.bf_done:
    ret

; ============================================================
; Error handling
; ============================================================
.err_missing_operand:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing
    mov     edx, str_missing_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

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

; ============================================================
; Utility functions
; ============================================================
do_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      do_write
    ret

do_write_err:
    mov     edi, STDERR
    jmp     do_write

do_exit:
    mov     eax, SYS_EXIT
    syscall

str_len:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     eax
    jmp     .sl_loop
.sl_done:
    ret

str_eq:
    xor     r8d, r8d
.se_loop:
    movzx   eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    cmp     al, dl
    jne     .se_ne
    test    al, al
    jz      .se_eq
    inc     r8d
    jmp     .se_loop
.se_eq:
    mov     eax, 1
    ret
.se_ne:
    xor     eax, eax
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: printf FORMAT [ARGUMENT]...", 10
    db "   or: printf OPTION", 10
    db "Print ARGUMENT(s) according to FORMAT, or execute according to OPTION:", 10, 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "FORMAT controls the output as in C printf.  Interpreted sequences:", 10
    db '  \"      double quote', 10
    db "  \\      backslash", 10
    db "  \a      alert (BEL)", 10
    db "  \b      backspace", 10
    db "  \c      produce no further output", 10
    db "  \e      escape", 10
    db "  \f      form feed", 10
    db "  \n      new line", 10
    db "  \r      carriage return", 10
    db "  \t      horizontal tab", 10
    db "  \v      vertical tab", 10
    db "  \NNN    byte with octal value NNN (1 to 3 digits)", 10
    db "  \xHH    byte with hexadecimal value HH (1 to 2 digits)", 10
    db "  \uHHHH  Unicode (ISO/IEC 10646) character with hex value HHHH (4 digits)", 10
    db "  \UHHHHHHHH  Unicode character with hex value HHHHHHHH (8 digits)", 10
    db "  %%      a single %", 10
    db "  %b      ARGUMENT as a string with '\' escapes interpreted,", 10
    db "          except that octal escapes are of the form \0 or \0NNN", 10, 10
    db "and all C format specifications ending with one of diouxXeEfFgGaAcs.", 10
    db "ARGUMENTs are converted according to format; those following %%noneq", 10
    db "are not.  Excess ARGUMENTs are recycled through FORMAT.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/printf>", 10
    db "or available locally via: info '(coreutils) printf invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "printf (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by David MacKenzie.", 10
str_version_len equ $ - str_version

str_prefix:      db "printf: "
str_prefix_len   equ $ - str_prefix
str_missing:     db "missing operand", 10
str_missing_len  equ $ - str_missing
str_try:         db "Try 'printf --help' for more information.", 10
str_try_len      equ $ - str_try
; @@DATA_END@@

str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0

str_dotzeroes:   db ".000000"
str_fzero:       db "0.000000"
str_fzero_len    equ $ - str_fzero

file_size equ $ - $$
