%include "include/linux.inc"

global parse_echo_flags

section .text

; parse_echo_flags(rdi=argc, rsi=argv)
; Returns:
;   rax = index of first non-flag argument (1-based, i.e., argv index)
;   dl  = flags byte: bit 0 = no_newline (-n), bit 1 = interpret_escapes (-e)
;
; Parses leading arguments that are valid echo flags.
; A valid flag arg starts with '-' and contains only 'n', 'e', 'E' chars.
; Parsing stops at first non-flag argument.
; Bare "-" is not a flag. Arguments starting with "--" are not flags.
parse_echo_flags:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, rdi        ; argc
    mov     r13, rsi        ; argv
    xor     r14d, r14d      ; flags = 0 (bit0=no_newline, bit1=escapes)
    mov     rbx, 1          ; start at argv[1]

.next_arg:
    cmp     rbx, r12
    jge     .done           ; no more args

    mov     rdi, [r13 + rbx * 8]  ; argv[rbx]

    ; Check first char is '-'
    cmp     byte [rdi], '-'
    jne     .done

    ; Check length >= 2 (not bare "-")
    cmp     byte [rdi + 1], 0
    je      .done

    ; Scan remaining chars - all must be n, e, or E
    lea     rsi, [rdi + 1]  ; start after '-'
    ; First, save current flags so we can update atomically
    mov     ecx, r14d       ; temp copy of flags

.scan_char:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .flag_valid     ; all chars checked, flag is valid

    cmp     al, 'n'
    je      .set_n
    cmp     al, 'e'
    je      .set_e
    cmp     al, 'E'
    je      .set_E

    ; Invalid char - this arg is not a flag
    jmp     .done

.set_n:
    or      ecx, 1          ; bit 0 = no_newline
    inc     rsi
    jmp     .scan_char

.set_e:
    or      ecx, 2          ; bit 1 = interpret_escapes
    inc     rsi
    jmp     .scan_char

.set_E:
    and     ecx, ~2         ; clear bit 1 (disable escapes)
    inc     rsi
    jmp     .scan_char

.flag_valid:
    mov     r14d, ecx       ; commit flag changes
    inc     rbx             ; move to next arg
    jmp     .next_arg

.done:
    mov     rax, rbx        ; return arg index
    mov     edx, r14d       ; return flags

    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
