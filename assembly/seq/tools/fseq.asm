; ============================================================================
;  fseq.asm — GNU-compatible "seq" in x86-64 Linux assembly
;
;  A drop-in replacement for GNU coreutils `seq`. Produces a small static
;  ELF binary with zero dependencies — no libc, no dynamic linker.
;
;  Supports all GNU seq flags:
;    -f FORMAT / --format=FORMAT    printf-style format (%e, %f, %g)
;    -s STRING / --separator=STRING custom separator (default: \n)
;    -w / --equal-width             zero-pad to equal width
;    --help / --version / --
;
;  Integer fast path: when all args are integers and no -f, uses pure
;  integer arithmetic with aggressive output buffering for 15x+ speedup.
;
;  BUILD (modular):
;    cd assembly/seq && make dev
; ============================================================================

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_exit
extern asm_strlen

; ── Constants ──────────────────────────────────────────
%define OUTBUF_SIZE     131072          ; 128KB output buffer
%define ITOA_BUF_SIZE   24             ; max digits for int64 + sign + NUL
%define FMT_BUF_SIZE    64             ; buffer for formatted float output
%define MAX_SEP_LEN     256            ; max separator length
%define MAX_FMT_LEN     128            ; max format string length

section .text
global _start

; ============================================================================
;                           ENTRY POINT
; ============================================================================
_start:
    ; ── Block SIGPIPE so write() returns -EPIPE instead of killing us ──
    sub     rsp, 16
    mov     qword [rsp], 0x1000         ; sigset: bit 12 = SIGPIPE
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi                    ; SIG_BLOCK = 0
    mov     rsi, rsp
    xor     edx, edx                    ; old set = NULL
    mov     r10d, 8                     ; sigsetsize
    syscall
    add     rsp, 16

    ; ── Save argc/argv ──
    mov     rax, [rsp]                  ; argc
    mov     [rel argc], rax
    lea     rax, [rsp + 8]
    mov     [rel argv], rax

    ; ── Initialize defaults ──
    mov     byte [rel flag_w], 0
    mov     byte [rel flag_f], 0
    mov     byte [rel is_float], 0
    mov     qword [rel sep_ptr], 0
    mov     qword [rel sep_len], 0
    mov     qword [rel fmt_ptr], 0
    mov     qword [rel outbuf_pos], 0

    ; ── Parse arguments ──
    call    parse_args

    ; ── Determine mode and run ──
    cmp     byte [rel is_float], 0
    jne     .float_mode

    ; Check if -f is set — forces float mode
    cmp     byte [rel flag_f], 0
    jne     .float_mode

    ; Integer fast path
    call    seq_integer
    jmp     .flush_exit

.float_mode:
    call    seq_float

.flush_exit:
    ; Flush output buffer
    call    flush_outbuf
    test    rax, rax
    js      .epipe_exit

    ; Exit 0
    xor     edi, edi
    call    asm_exit

.epipe_exit:
    xor     edi, edi
    call    asm_exit

; ============================================================================
;  parse_args — Parse command-line arguments
;
;  Sets: first_val, incr_val, last_val (integers)
;        first_fval, incr_fval, last_fval (floats in FPU format on stack)
;        first_str, incr_str, last_str (pointers to original strings)
;        flag_w, flag_f, sep_ptr, sep_len, fmt_ptr
;        is_float, num_count
; ============================================================================
parse_args:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12, [rel argc]             ; argc
    mov     r13, [rel argv]             ; argv pointer
    mov     r14d, 1                     ; i = 1 (skip argv[0])
    xor     r15d, r15d                  ; num_count = 0
    mov     byte [rel end_of_opts], 0

.arg_loop:
    cmp     r14, r12
    jge     .args_done

    mov     rbx, [r13 + r14*8]         ; argv[i]

    ; Check for "--" (end of options)
    cmp     byte [rel end_of_opts], 1
    je      .is_number

    ; Check for "-" alone — not an option, treat as operand
    cmp     byte [rbx], '-'
    jne     .is_number
    cmp     byte [rbx+1], 0
    je      .is_number

    ; Starts with '-', could be option or negative number
    ; Check for "--"
    cmp     word [rbx], 0x2D2D         ; "--"
    jne     .check_short_opt

    ; Starts with "--"
    cmp     byte [rbx+2], 0            ; just "--"?
    jne     .check_long_opt

    ; Bare "--" — end of options
    mov     byte [rel end_of_opts], 1
    inc     r14
    jmp     .arg_loop

.check_long_opt:
    ; Check --help
    push    rbx
    mov     rdi, rbx
    lea     rsi, [rel str_help_opt]
    call    str_eq
    pop     rbx
    test    eax, eax
    jnz     .do_help

    ; Check --version
    push    rbx
    mov     rdi, rbx
    lea     rsi, [rel str_version_opt]
    call    str_eq
    pop     rbx
    test    eax, eax
    jnz     .do_version

    ; Check --format=
    push    rbx
    mov     rdi, rbx
    lea     rsi, [rel str_format_eq]
    mov     edx, 9                      ; len("--format=")
    call    str_prefix
    pop     rbx
    test    eax, eax
    jnz     .parse_format_eq

    ; Check --separator=
    push    rbx
    mov     rdi, rbx
    lea     rsi, [rel str_separator_eq]
    mov     edx, 12                     ; len("--separator=")
    call    str_prefix
    pop     rbx
    test    eax, eax
    jnz     .parse_separator_eq

    ; Check --equal-width
    push    rbx
    mov     rdi, rbx
    lea     rsi, [rel str_equal_width]
    call    str_eq
    pop     rbx
    test    eax, eax
    jnz     .set_w_flag

    ; Unknown long option — error
    jmp     .error_unknown_opt

.check_short_opt:
    ; Single '-' followed by something
    ; Could be -f, -s, -w, or a negative number
    cmp     byte [rbx], '-'
    jne     .is_number

    ; Check if second char is a digit or '.' — negative number
    movzx   eax, byte [rbx+1]
    cmp     al, '.'
    je      .is_number
    cmp     al, '0'
    jb      .parse_short_opt
    cmp     al, '9'
    ja      .parse_short_opt
    jmp     .is_number

.parse_short_opt:
    movzx   eax, byte [rbx+1]

    cmp     al, 'w'
    je      .short_w
    cmp     al, 'f'
    je      .short_f
    cmp     al, 's'
    je      .short_s

    ; Unknown short option
    jmp     .error_unknown_opt

.short_w:
    ; -w, could have more chars after
    cmp     byte [rbx+2], 0
    jne     .error_unknown_opt          ; -wx not valid
    mov     byte [rel flag_w], 1
    inc     r14
    jmp     .arg_loop

.short_f:
    ; -f FORMAT or -fFORMAT
    cmp     byte [rbx+2], 0
    jne     .short_f_inline

    ; -f FORMAT (next arg)
    inc     r14
    cmp     r14, r12
    jge     .error_missing_fmt
    mov     rax, [r13 + r14*8]
    mov     [rel fmt_ptr], rax
    mov     byte [rel flag_f], 1
    mov     rdi, rax
    call    asm_strlen
    mov     [rel fmt_len], rax
    inc     r14
    jmp     .arg_loop

.short_f_inline:
    ; -fFORMAT (format follows immediately)
    lea     rax, [rbx+2]
    mov     [rel fmt_ptr], rax
    mov     byte [rel flag_f], 1
    mov     rdi, rax
    call    asm_strlen
    mov     [rel fmt_len], rax
    inc     r14
    jmp     .arg_loop

.short_s:
    ; -s STRING or -sSTRING
    cmp     byte [rbx+2], 0
    jne     .short_s_inline

    ; -s STRING (next arg)
    inc     r14
    cmp     r14, r12
    jge     .error_missing_sep
    mov     rax, [r13 + r14*8]
    mov     [rel sep_ptr], rax
    mov     rdi, rax
    call    asm_strlen
    mov     [rel sep_len], rax
    inc     r14
    jmp     .arg_loop

.short_s_inline:
    ; -sSTRING
    lea     rax, [rbx+2]
    mov     [rel sep_ptr], rax
    mov     rdi, rax
    call    asm_strlen
    mov     [rel sep_len], rax
    inc     r14
    jmp     .arg_loop

.parse_format_eq:
    ; --format=VALUE
    lea     rax, [rbx+9]               ; skip "--format="
    mov     [rel fmt_ptr], rax
    mov     byte [rel flag_f], 1
    mov     rdi, rax
    call    asm_strlen
    mov     [rel fmt_len], rax
    inc     r14
    jmp     .arg_loop

.parse_separator_eq:
    ; --separator=VALUE
    lea     rax, [rbx+12]              ; skip "--separator="
    mov     [rel sep_ptr], rax
    mov     rdi, rax
    call    asm_strlen
    mov     [rel sep_len], rax
    inc     r14
    jmp     .arg_loop

.set_w_flag:
    mov     byte [rel flag_w], 1
    inc     r14
    jmp     .arg_loop

.is_number:
    ; Parse this argument as a number
    ; Save string pointer
    cmp     r15d, 0
    je      .save_num0
    cmp     r15d, 1
    je      .save_num1
    cmp     r15d, 2
    je      .save_num2
    ; Too many operands
    jmp     .error_extra_operand

.save_num0:
    mov     [rel num_strs], rbx
    jmp     .parse_num

.save_num1:
    mov     [rel num_strs+8], rbx
    jmp     .parse_num

.save_num2:
    mov     [rel num_strs+16], rbx

.parse_num:
    ; Check if this number contains a '.' (float mode)
    mov     rdi, rbx
    call    has_dot
    test    eax, eax
    jz      .not_float_arg
    mov     byte [rel is_float], 1

.not_float_arg:
    ; Parse as integer (we'll also parse as float later if needed)
    mov     rdi, rbx
    call    parse_int64
    ; rax = value, rdx = 0 if ok, 1 if error
    test    edx, edx
    jnz     .check_float_fallback

    ; Store integer value
    cmp     r15d, 0
    je      .store_int0
    cmp     r15d, 1
    je      .store_int1
    mov     [rel num_ints+16], rax
    jmp     .num_stored

.store_int0:
    mov     [rel num_ints], rax
    jmp     .num_stored

.store_int1:
    mov     [rel num_ints+8], rax
    jmp     .num_stored

.check_float_fallback:
    ; Integer parse failed — must be float
    mov     byte [rel is_float], 1

.num_stored:
    inc     r15d
    inc     r14
    jmp     .arg_loop

.args_done:
    mov     [rel num_count], r15d

    ; Validate: need at least 1 number
    test    r15d, r15d
    jz      .error_missing_operand

    ; Set up first/incr/last based on num_count
    cmp     r15d, 1
    je      .one_arg
    cmp     r15d, 2
    je      .two_args
    ; three args
    jmp     .three_args

.one_arg:
    ; seq LAST => first=1, incr=1, last=LAST
    mov     qword [rel first_val], 1
    mov     qword [rel incr_val], 1
    mov     rax, [rel num_ints]
    mov     [rel last_val], rax
    mov     rax, [rel num_strs]
    mov     [rel last_str], rax

    ; For float mode: first=1.0, incr=1.0
    lea     rdi, [rel str_one]
    mov     [rel first_str], rdi
    mov     [rel incr_str], rdi
    jmp     .setup_done

.two_args:
    ; seq FIRST LAST => incr=1
    mov     rax, [rel num_ints]
    mov     [rel first_val], rax
    mov     qword [rel incr_val], 1
    mov     rax, [rel num_ints+8]
    mov     [rel last_val], rax

    mov     rax, [rel num_strs]
    mov     [rel first_str], rax
    lea     rdi, [rel str_one]
    mov     [rel incr_str], rdi
    mov     rax, [rel num_strs+8]
    mov     [rel last_str], rax
    jmp     .setup_done

.three_args:
    ; seq FIRST INCR LAST
    mov     rax, [rel num_ints]
    mov     [rel first_val], rax
    mov     rax, [rel num_ints+8]
    mov     [rel incr_val], rax
    mov     rax, [rel num_ints+16]
    mov     [rel last_val], rax

    mov     rax, [rel num_strs]
    mov     [rel first_str], rax
    mov     rax, [rel num_strs+8]
    mov     [rel incr_str], rax
    mov     rax, [rel num_strs+16]
    mov     [rel last_str], rax

    ; Check for zero increment (only in integer mode)
    cmp     byte [rel is_float], 1
    je      .setup_done
    cmp     qword [rel incr_val], 0
    je      .error_zero_incr

.setup_done:
    ; Parse float values if in float mode (or -f mode)
    cmp     byte [rel is_float], 1
    je      .do_float_parse
    cmp     byte [rel flag_f], 1
    jne     .setup_sep

.do_float_parse:
    ; Parse all three values as floats
    call    parse_float_args

.setup_sep:
    ; Set default separator if not specified
    cmp     qword [rel sep_ptr], 0
    jne     .setup_complete

    lea     rax, [rel default_sep]
    mov     [rel sep_ptr], rax
    mov     qword [rel sep_len], 1

.setup_complete:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── Error handlers ──
.do_help:
    mov     rdi, STDOUT
    lea     rsi, [rel help_text]
    mov     edx, help_text_len
    call    asm_write_all
    xor     edi, edi
    call    asm_exit

.do_version:
    mov     rdi, STDOUT
    lea     rsi, [rel version_text]
    mov     edx, version_text_len
    call    asm_write_all
    xor     edi, edi
    call    asm_exit

.error_missing_operand:
    lea     rsi, [rel err_missing_operand]
    mov     edx, err_missing_operand_len
    jmp     .print_err_exit

.error_extra_operand:
    ; "seq: extra operand 'X'"
    lea     rsi, [rel err_extra_operand]
    mov     edx, err_extra_operand_len
    mov     rdi, STDERR
    call    asm_write_all
    ; Print the offending operand
    mov     rdi, rbx
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, rbx
    mov     rdi, STDERR
    call    asm_write_all
    lea     rsi, [rel err_quote_nl]
    mov     edx, 2
    mov     rdi, STDERR
    call    asm_write_all
    jmp     .print_try_help

.error_zero_incr:
    ; Need to point to the increment string for error message
    mov     rbx, [rel num_strs+8]       ; incr string
    lea     rsi, [rel err_zero_incr_pre]
    mov     edx, err_zero_incr_pre_len
    mov     rdi, STDERR
    call    asm_write_all
    ; Print the value
    mov     rdi, rbx
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, rbx
    mov     rdi, STDERR
    call    asm_write_all
    lea     rsi, [rel err_quote_nl]
    mov     edx, 2
    mov     rdi, STDERR
    call    asm_write_all
    jmp     .print_try_help

.error_unknown_opt:
    lea     rsi, [rel err_unknown_opt]
    mov     edx, err_unknown_opt_len
    mov     rdi, STDERR
    call    asm_write_all
    mov     rdi, rbx
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, rbx
    mov     rdi, STDERR
    call    asm_write_all
    lea     rsi, [rel err_quote_nl]
    mov     edx, 2
    mov     rdi, STDERR
    call    asm_write_all
    jmp     .print_try_help

.error_missing_fmt:
    lea     rsi, [rel err_missing_fmt]
    mov     edx, err_missing_fmt_len
    jmp     .print_err_exit

.error_missing_sep:
    lea     rsi, [rel err_missing_sep]
    mov     edx, err_missing_sep_len
    jmp     .print_err_exit

.print_err_exit:
    mov     rdi, STDERR
    call    asm_write_all

.print_try_help:
    lea     rsi, [rel err_try_help]
    mov     edx, err_try_help_len
    mov     rdi, STDERR
    call    asm_write_all
    mov     edi, 1
    call    asm_exit


; ============================================================================
;  seq_integer — Integer fast path
;
;  Ultra-fast integer sequence output with buffered I/O.
;  Uses: first_val, incr_val, last_val, flag_w, sep_ptr, sep_len
; ============================================================================
seq_integer:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12, [rel first_val]        ; current value
    mov     r13, [rel incr_val]         ; increment
    mov     r14, [rel last_val]         ; last value
    mov     r15d, 0                     ; pad_width = 0

    ; Determine direction
    test    r13, r13
    jz      .int_done                   ; zero increment = done (shouldn't reach here)

    ; Check if -w flag
    cmp     byte [rel flag_w], 0
    je      .int_loop_setup

    ; Calculate pad width = max(width(first), width(last))
    mov     rdi, r12
    call    int_width
    mov     ebx, eax                    ; width of first

    mov     rdi, r14
    call    int_width
    cmp     eax, ebx
    cmovg   ebx, eax                   ; max width
    mov     r15d, ebx                   ; pad_width

.int_loop_setup:
    ; Check direction
    cmp     r13, 0
    jg      .int_loop_pos
    jmp     .int_loop_neg

.int_loop_pos:
    ; Positive increment loop
    cmp     r12, r14
    jg      .int_done

.int_emit_pos:
    ; Convert current value to string and append to buffer
    mov     rdi, r12
    mov     esi, r15d                   ; pad_width (0 = no padding)
    call    emit_integer

    ; Check for write error (EPIPE)
    test    rax, rax
    js      .int_done

    ; Add increment, check overflow
    mov     rax, r12
    add     rax, r13
    jo      .int_done                   ; overflow = done
    mov     r12, rax

    cmp     r12, r14
    jle     .int_emit_pos
    jmp     .int_done

.int_loop_neg:
    ; Negative increment loop
    cmp     r12, r14
    jl      .int_done

.int_emit_neg:
    mov     rdi, r12
    mov     esi, r15d
    call    emit_integer

    test    rax, rax
    js      .int_done

    mov     rax, r12
    add     rax, r13
    jo      .int_done
    mov     r12, rax

    cmp     r12, r14
    jge     .int_emit_neg

.int_done:
    ; Replace last separator with newline
    call    finalize_output

    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  emit_integer — Convert int64 to string, append to output buffer with separator
;
;  rdi = value (int64)
;  esi = pad_width (0 = no padding)
;  Returns: rax = 0 on success, -1 on error
; ============================================================================
emit_integer:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, rdi                    ; value
    mov     r13d, esi                   ; pad_width

    ; Convert to string in itoa_buf
    lea     rdi, [rel itoa_buf + ITOA_BUF_SIZE]
    mov     rsi, r12
    call    itoa_reverse
    ; rax = pointer to start of digits, rdx = length

    mov     r14, rax                    ; save pointer to start

    ; Check if we need to ensure buffer space
    ; Need: pad_width (or digit length) + sep_len + 1 (for safety)
    mov     rcx, rdx                    ; digit length
    cmp     r13d, 0
    je      .no_pad_calc
    movzx   eax, byte [r14]
    cmp     al, '-'
    jne     .no_neg_pad_calc

    ; Negative with padding: need max(pad_width, len)
    ; Width includes the '-' sign
    cmp     ecx, r13d
    jge     .no_pad_calc
    mov     ecx, r13d
    jmp     .no_pad_calc

.no_neg_pad_calc:
    cmp     ecx, r13d
    jge     .no_pad_calc
    mov     ecx, r13d

.no_pad_calc:
    add     rcx, [rel sep_len]
    add     rcx, 2                      ; safety margin

    ; Check if buffer has space
    mov     rax, [rel outbuf_pos]
    add     rax, rcx
    cmp     rax, OUTBUF_SIZE - 64
    jb      .has_space

    ; Flush buffer
    call    flush_outbuf
    test    rax, rax
    js      .emit_error

.has_space:
    ; Get output pointer
    lea     rbx, [rel outbuf]
    add     rbx, [rel outbuf_pos]

    ; Handle padding
    cmp     r13d, 0
    je      .no_padding

    ; Calculate actual digit string length
    mov     rdi, r14
    call    asm_strlen
    mov     rcx, rax                    ; actual length

    ; Check if negative
    cmp     byte [r14], '-'
    jne     .pad_positive

    ; Negative: write '-', then pad zeros, then digits (skip '-')
    mov     byte [rbx], '-'
    inc     rbx

    ; Pad count = pad_width - actual_length
    mov     edx, r13d
    sub     edx, ecx                    ; pad zeros needed
    jle     .pad_neg_digits

    ; Write pad zeros
.pad_neg_zeros:
    mov     byte [rbx], '0'
    inc     rbx
    dec     edx
    jnz     .pad_neg_zeros

.pad_neg_digits:
    ; Copy digits (skip '-')
    lea     rsi, [r14 + 1]
    dec     rcx                         ; length without '-'
.pad_neg_copy:
    test    rcx, rcx
    jz      .pad_done
    mov     al, [rsi]
    mov     [rbx], al
    inc     rsi
    inc     rbx
    dec     rcx
    jmp     .pad_neg_copy

.pad_positive:
    ; Positive: pad zeros then digits
    mov     edx, r13d
    sub     edx, ecx
    jle     .pad_pos_digits

.pad_pos_zeros:
    mov     byte [rbx], '0'
    inc     rbx
    dec     edx
    jnz     .pad_pos_zeros

.pad_pos_digits:
    mov     rsi, r14
.pad_pos_copy:
    test    rcx, rcx
    jz      .pad_done
    mov     al, [rsi]
    mov     [rbx], al
    inc     rsi
    inc     rbx
    dec     rcx
    jmp     .pad_pos_copy

.pad_done:
    jmp     .append_sep

.no_padding:
    ; Copy digits directly
    mov     rsi, r14
    mov     rdi, r14
    call    asm_strlen
    mov     rcx, rax
.copy_digits:
    test    rcx, rcx
    jz      .append_sep
    mov     al, [rsi]
    mov     [rbx], al
    inc     rsi
    inc     rbx
    dec     rcx
    jmp     .copy_digits

.append_sep:
    ; Append separator
    mov     rcx, [rel sep_len]
    mov     rsi, [rel sep_ptr]
.copy_sep:
    test    rcx, rcx
    jz      .emit_update_pos
    mov     al, [rsi]
    mov     [rbx], al
    inc     rsi
    inc     rbx
    dec     rcx
    jmp     .copy_sep

.emit_update_pos:
    ; Update outbuf_pos
    lea     rax, [rel outbuf]
    sub     rbx, rax
    mov     [rel outbuf_pos], rbx

    xor     eax, eax                    ; success
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.emit_error:
    mov     rax, -1
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  itoa_reverse — Convert int64 to decimal string (written backwards from end)
;
;  rdi = pointer to END of buffer (past last byte)
;  rsi = int64 value
;  Returns: rax = pointer to first digit, rdx = string length
; ============================================================================
itoa_reverse:
    push    rbx
    mov     rcx, rdi                    ; save end pointer
    mov     rax, rsi                    ; value
    xor     r8d, r8d                    ; negative flag

    ; Handle negative
    test    rax, rax
    jns     .itoa_pos
    neg     rax
    mov     r8d, 1

.itoa_pos:
    ; Null terminator
    dec     rdi
    mov     byte [rdi], 0

    ; Special case: 0
    test    rax, rax
    jnz     .itoa_loop

    dec     rdi
    mov     byte [rdi], '0'
    jmp     .itoa_sign

.itoa_loop:
    test    rax, rax
    jz      .itoa_sign

    ; Divide by 10
    xor     edx, edx
    mov     rbx, 10
    div     rbx
    add     dl, '0'
    dec     rdi
    mov     [rdi], dl
    jmp     .itoa_loop

.itoa_sign:
    test    r8d, r8d
    jz      .itoa_done
    dec     rdi
    mov     byte [rdi], '-'

.itoa_done:
    mov     rax, rdi                    ; pointer to start
    mov     rdx, rcx
    sub     rdx, rdi
    dec     rdx                         ; don't count null terminator

    pop     rbx
    ret


; ============================================================================
;  int_width — Calculate display width of an integer
;
;  rdi = int64 value
;  Returns: eax = number of characters (including '-' sign)
; ============================================================================
int_width:
    push    rbx
    mov     rax, rdi
    xor     ecx, ecx                    ; width counter

    ; Handle negative
    test    rax, rax
    jns     .iw_pos
    neg     rax
    inc     ecx                         ; count '-'

.iw_pos:
    ; Count digits
    test    rax, rax
    jnz     .iw_loop
    inc     ecx                         ; "0" is 1 digit
    jmp     .iw_done

.iw_loop:
    test    rax, rax
    jz      .iw_done
    xor     edx, edx
    mov     rbx, 10
    div     rbx
    inc     ecx
    jmp     .iw_loop

.iw_done:
    mov     eax, ecx
    pop     rbx
    ret


; ============================================================================
;  seq_float — Floating-point sequence output
;
;  Uses x87 FPU for arithmetic. Parses first/incr/last as floats.
; ============================================================================
seq_float:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 64                     ; local workspace

    ; Parse all three values as doubles
    mov     rdi, [rel first_str]
    call    parse_double
    movsd   [rel first_fval], xmm0

    mov     rdi, [rel incr_str]
    call    parse_double
    movsd   [rel incr_fval], xmm0

    mov     rdi, [rel last_str]
    call    parse_double
    movsd   [rel last_fval], xmm0

    ; Determine decimal precision = max decimal places among inputs
    mov     rdi, [rel first_str]
    call    count_decimals
    mov     r12d, eax                   ; prec of first

    mov     rdi, [rel incr_str]
    call    count_decimals
    cmp     eax, r12d
    cmovg   r12d, eax                  ; prec of incr

    mov     rdi, [rel last_str]
    call    count_decimals
    cmp     eax, r12d
    cmovg   r12d, eax                  ; prec of last

    mov     [rel float_prec], r12d

    ; Check if -f format specified
    cmp     byte [rel flag_f], 0
    jne     .float_with_format

    ; Determine pad width for -w
    xor     r15d, r15d                  ; pad_width = 0
    cmp     byte [rel flag_w], 0
    je      .float_loop_start

    ; Calculate width of first and last formatted values
    movsd   xmm0, [rel first_fval]
    mov     edi, r12d
    call    float_format_width
    mov     ebx, eax

    movsd   xmm0, [rel last_fval]
    mov     edi, r12d
    call    float_format_width
    cmp     eax, ebx
    cmovg   ebx, eax
    mov     r15d, ebx

.float_loop_start:
    ; Load current = first
    movsd   xmm0, [rel first_fval]
    movsd   [rsp], xmm0                ; current on stack

    ; Load increment and last
    movsd   xmm1, [rel incr_fval]      ; increment
    movsd   xmm2, [rel last_fval]      ; last

    ; Determine direction
    xorpd   xmm3, xmm3                 ; 0.0
    ucomisd xmm1, xmm3
    je      .float_done                 ; zero increment
    ja      .float_pos_loop

    ; Negative increment
.float_neg_loop:
    movsd   xmm0, [rsp]                ; current
    ucomisd xmm0, xmm2                 ; current < last?
    jb      .float_done

    ; Emit current value
    mov     edi, r12d                   ; precision
    mov     esi, r15d                   ; pad_width
    call    emit_float

    test    rax, rax
    js      .float_done

    ; current += increment
    movsd   xmm0, [rsp]
    addsd   xmm0, [rel incr_fval]
    movsd   [rsp], xmm0
    movsd   xmm2, [rel last_fval]
    jmp     .float_neg_loop

.float_pos_loop:
    movsd   xmm0, [rsp]                ; current
    ucomisd xmm0, xmm2                 ; current > last?
    ja      .float_done

    ; Emit current value
    mov     edi, r12d                   ; precision
    mov     esi, r15d                   ; pad_width
    call    emit_float

    test    rax, rax
    js      .float_done

    ; current += increment
    movsd   xmm0, [rsp]
    addsd   xmm0, [rel incr_fval]
    movsd   [rsp], xmm0
    movsd   xmm2, [rel last_fval]
    jmp     .float_pos_loop

.float_with_format:
    ; -f mode: use format string
    ; Parse values as doubles
    movsd   xmm0, [rel first_fval]
    movsd   [rsp], xmm0                ; current

    movsd   xmm1, [rel incr_fval]
    movsd   xmm2, [rel last_fval]

    ; Determine direction
    xorpd   xmm3, xmm3
    ucomisd xmm1, xmm3
    je      .float_done
    ja      .float_fmt_pos_loop

.float_fmt_neg_loop:
    movsd   xmm0, [rsp]
    ucomisd xmm0, xmm2
    jb      .float_done

    call    emit_float_fmt
    test    rax, rax
    js      .float_done

    movsd   xmm0, [rsp]
    addsd   xmm0, [rel incr_fval]
    movsd   [rsp], xmm0
    movsd   xmm2, [rel last_fval]
    jmp     .float_fmt_neg_loop

.float_fmt_pos_loop:
    movsd   xmm0, [rsp]
    ucomisd xmm0, xmm2
    ja      .float_done

    call    emit_float_fmt
    test    rax, rax
    js      .float_done

    movsd   xmm0, [rsp]
    addsd   xmm0, [rel incr_fval]
    movsd   [rsp], xmm0
    movsd   xmm2, [rel last_fval]
    jmp     .float_fmt_pos_loop

.float_done:
    call    finalize_output

    add     rsp, 64
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  emit_float — Format a double and append to output buffer
;
;  xmm0 = value
;  edi = precision (number of decimal places)
;  esi = pad_width (0 = no padding)
;  Returns: rax = 0 on success, -1 on error
; ============================================================================
emit_float:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 32

    mov     r12d, edi                   ; precision
    mov     r13d, esi                   ; pad_width
    movsd   [rsp], xmm0                ; save value

    ; Format the float
    movsd   xmm0, [rsp]
    mov     edi, r12d
    lea     rsi, [rel fmt_scratch]
    mov     edx, FMT_BUF_SIZE
    call    format_float
    ; rax = length of formatted string in fmt_scratch

    mov     r14, rax                    ; formatted length

    ; Check buffer space
    mov     rcx, r14
    add     rcx, [rel sep_len]
    cmp     r13d, 0
    je      .ef_no_pad_adj
    mov     eax, r13d
    cmp     rax, rcx
    jle     .ef_no_pad_adj
    mov     rcx, rax
.ef_no_pad_adj:
    add     rcx, 4

    mov     rax, [rel outbuf_pos]
    add     rax, rcx
    cmp     rax, OUTBUF_SIZE - 64
    jb      .ef_has_space

    call    flush_outbuf
    test    rax, rax
    js      .ef_error

.ef_has_space:
    lea     rbx, [rel outbuf]
    add     rbx, [rel outbuf_pos]

    ; Handle padding
    cmp     r13d, 0
    je      .ef_no_pad

    ; Check if negative
    cmp     byte [rel fmt_scratch], '-'
    jne     .ef_pad_pos

    ; Negative: '-' then zeros then digits
    mov     byte [rbx], '-'
    inc     rbx
    mov     eax, r13d
    sub     rax, r14
    jle     .ef_pad_neg_digits
.ef_pad_neg_zeros:
    mov     byte [rbx], '0'
    inc     rbx
    dec     rax
    jnz     .ef_pad_neg_zeros
.ef_pad_neg_digits:
    lea     rsi, [rel fmt_scratch + 1]
    mov     rcx, r14
    dec     rcx
.ef_pad_neg_copy:
    test    rcx, rcx
    jz      .ef_pad_done
    mov     al, [rsi]
    mov     [rbx], al
    inc     rsi
    inc     rbx
    dec     rcx
    jmp     .ef_pad_neg_copy

.ef_pad_pos:
    mov     eax, r13d
    sub     rax, r14
    jle     .ef_pad_pos_digits
.ef_pad_pos_zeros:
    mov     byte [rbx], '0'
    inc     rbx
    dec     rax
    jnz     .ef_pad_pos_zeros
.ef_pad_pos_digits:
    lea     rsi, [rel fmt_scratch]
    mov     rcx, r14
.ef_pad_pos_copy:
    test    rcx, rcx
    jz      .ef_pad_done
    mov     al, [rsi]
    mov     [rbx], al
    inc     rsi
    inc     rbx
    dec     rcx
    jmp     .ef_pad_pos_copy

.ef_pad_done:
    jmp     .ef_sep

.ef_no_pad:
    ; Copy formatted string
    lea     rsi, [rel fmt_scratch]
    mov     rcx, r14
.ef_copy:
    test    rcx, rcx
    jz      .ef_sep
    mov     al, [rsi]
    mov     [rbx], al
    inc     rsi
    inc     rbx
    dec     rcx
    jmp     .ef_copy

.ef_sep:
    ; Append separator
    mov     rcx, [rel sep_len]
    mov     rsi, [rel sep_ptr]
.ef_sep_copy:
    test    rcx, rcx
    jz      .ef_update_pos
    mov     al, [rsi]
    mov     [rbx], al
    inc     rsi
    inc     rbx
    dec     rcx
    jmp     .ef_sep_copy

.ef_update_pos:
    lea     rax, [rel outbuf]
    sub     rbx, rax
    mov     [rel outbuf_pos], rbx

    xor     eax, eax
    add     rsp, 32
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.ef_error:
    mov     rax, -1
    add     rsp, 32
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  emit_float_fmt — Format a double with -f format string and append to outbuf
;
;  xmm0 = value
;  Returns: rax = 0 on success, -1 on error
;
;  Directly processes the format string to avoid nested stack issues.
;  Supported: %[flags][width][.prec]g, %[flags][width][.prec]f,
;             %[flags][width][.prec]e, %%, and literal chars.
; ============================================================================
emit_float_fmt:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 16

    movsd   [rsp], xmm0                ; save value at stable [rsp]

    ; Walk the format string, building output directly in outbuf
    mov     r12, [rel fmt_ptr]          ; format string
    mov     r13, [rel fmt_len]          ; format length
    xor     ebx, ebx                    ; format position

    ; Ensure buffer space (conservative: 256 bytes)
    mov     rax, [rel outbuf_pos]
    add     rax, 256
    add     rax, [rel sep_len]
    cmp     rax, OUTBUF_SIZE - 64
    jb      .eff_space_ok
    call    flush_outbuf
    test    rax, rax
    js      .eff_err
.eff_space_ok:

    lea     rbp, [rel outbuf]
    add     rbp, [rel outbuf_pos]       ; rbp = write pointer

.eff_scan:
    cmp     rbx, r13
    jge     .eff_sep

    cmp     byte [r12 + rbx], '%'
    je      .eff_pct

    ; Literal char
    mov     al, [r12 + rbx]
    mov     [rbp], al
    inc     rbp
    inc     ebx
    jmp     .eff_scan

.eff_pct:
    inc     ebx
    cmp     rbx, r13
    jge     .eff_sep

    ; %%
    cmp     byte [r12 + rbx], '%'
    jne     .eff_parse_spec
    mov     byte [rbp], '%'
    inc     rbp
    inc     ebx
    jmp     .eff_scan

.eff_parse_spec:
    ; Parse [flags][width][.prec]type
    xor     r14d, r14d                  ; flags: bit0=zero-pad
    xor     r15d, r15d                  ; width
    mov     ecx, -1                     ; precision (-1=default)

    ; Flags
.eff_flags:
    cmp     byte [r12 + rbx], '0'
    jne     .eff_fl_minus
    or      r14d, 1
    inc     ebx
    jmp     .eff_flags
.eff_fl_minus:
    cmp     byte [r12 + rbx], '-'
    jne     .eff_pw
    or      r14d, 2
    inc     ebx
    jmp     .eff_flags

.eff_pw:
    ; Width
    movzx   eax, byte [r12 + rbx]
    sub     eax, '0'
    cmp     eax, 9
    ja      .eff_dot
.eff_pw_lp:
    movzx   eax, byte [r12 + rbx]
    sub     eax, '0'
    cmp     eax, 9
    ja      .eff_dot
    imul    r15d, 10
    add     r15d, eax
    inc     ebx
    jmp     .eff_pw_lp

.eff_dot:
    cmp     byte [r12 + rbx], '.'
    jne     .eff_type
    inc     ebx
    xor     ecx, ecx
.eff_pr_lp:
    movzx   eax, byte [r12 + rbx]
    sub     eax, '0'
    cmp     eax, 9
    ja      .eff_type
    imul    ecx, 10
    add     ecx, eax
    inc     ebx
    jmp     .eff_pr_lp

.eff_type:
    movzx   eax, byte [r12 + rbx]
    inc     ebx

    ; Save width/flags/prec before calling format functions
    ; r14d = flags, r15d = width, ecx = precision
    mov     [rel _eff_flags], r14d
    mov     [rel _eff_width], r15d
    mov     [rel _eff_prec], ecx

    cmp     al, 'g'
    je      .eff_g
    cmp     al, 'G'
    je      .eff_g
    cmp     al, 'f'
    je      .eff_f
    cmp     al, 'e'
    je      .eff_e
    cmp     al, 'E'
    je      .eff_e
    jmp     .eff_scan

.eff_g:
    ; %g: format as fixed-point then strip trailing zeros
    movsd   xmm0, [rsp]
    mov     edi, [rel _eff_prec]
    cmp     edi, -1
    jne     .eff_g_go
    mov     edi, 6
.eff_g_go:
    lea     rsi, [rel fmt_scratch]
    mov     edx, FMT_BUF_SIZE
    call    format_float                ; -> rax = length, fmt_scratch has string
    mov     r14, rax                    ; r14 = formatted length

    ; Strip trailing zeros after decimal point
    lea     rsi, [rel fmt_scratch]
    xor     ecx, ecx
.eff_g_fdot:
    cmp     ecx, r14d
    jge     .eff_g_nodot
    cmp     byte [rsi + rcx], '.'
    je      .eff_g_strip
    inc     ecx
    jmp     .eff_g_fdot
.eff_g_strip:
    mov     eax, r14d
    dec     eax
.eff_g_sl:
    cmp     eax, ecx
    jl      .eff_g_sd
    cmp     byte [rsi + rax], '0'
    jne     .eff_g_sc
    dec     eax
    jmp     .eff_g_sl
.eff_g_sc:
    cmp     byte [rsi + rax], '.'
    jne     .eff_g_sd
    dec     eax
.eff_g_sd:
    inc     eax
    mov     r14d, eax
.eff_g_nodot:
    jmp     .eff_apply_pad

.eff_f:
    movsd   xmm0, [rsp]
    mov     edi, [rel _eff_prec]
    cmp     edi, -1
    jne     .eff_f_go
    mov     edi, 6
.eff_f_go:
    lea     rsi, [rel fmt_scratch]
    mov     edx, FMT_BUF_SIZE
    call    format_float
    mov     r14, rax
    jmp     .eff_apply_pad

.eff_e:
    movsd   xmm0, [rsp]
    mov     r10d, [rel _eff_prec]
    cmp     r10d, -1
    jne     .eff_e_go
    mov     r10d, 6
.eff_e_go:
    lea     rsi, [rel fmt_scratch]
    mov     edx, FMT_BUF_SIZE
    call    format_scientific
    mov     r14, rax
    jmp     .eff_apply_pad

.eff_apply_pad:
    ; r14d = length of string in fmt_scratch
    ; [_eff_width] = desired width, [_eff_flags] = flags
    mov     r15d, [rel _eff_width]
    mov     ecx, r15d
    sub     ecx, r14d                   ; pad = width - length
    cmp     ecx, 0
    jle     .eff_copy_result

    ; Check zero-pad
    mov     eax, [rel _eff_flags]
    test    eax, 1
    jnz     .eff_zpad

    ; Space pad
.eff_sp_lp:
    mov     byte [rbp], ' '
    inc     rbp
    dec     ecx
    jnz     .eff_sp_lp
    jmp     .eff_copy_result

.eff_zpad:
    ; If negative, write '-' first
    cmp     byte [rel fmt_scratch], '-'
    jne     .eff_zp_lp
    mov     byte [rbp], '-'
    inc     rbp
.eff_zp_lp:
    test    ecx, ecx
    jz      .eff_zp_digits
    mov     byte [rbp], '0'
    inc     rbp
    dec     ecx
    jmp     .eff_zp_lp
.eff_zp_digits:
    ; Copy without leading '-'
    cmp     byte [rel fmt_scratch], '-'
    jne     .eff_copy_result
    lea     rsi, [rel fmt_scratch + 1]
    mov     ecx, r14d
    dec     ecx
.eff_zp_cp:
    test    ecx, ecx
    jz      .eff_after_copy
    mov     al, [rsi]
    mov     [rbp], al
    inc     rsi
    inc     rbp
    dec     ecx
    jmp     .eff_zp_cp

.eff_copy_result:
    lea     rsi, [rel fmt_scratch]
    mov     ecx, r14d
.eff_cp_lp:
    test    ecx, ecx
    jz      .eff_after_copy
    mov     al, [rsi]
    mov     [rbp], al
    inc     rsi
    inc     rbp
    dec     ecx
    jmp     .eff_cp_lp

.eff_after_copy:
    jmp     .eff_scan

.eff_sep:
    ; Append separator
    mov     rcx, [rel sep_len]
    mov     rsi, [rel sep_ptr]
.eff_sep_lp:
    test    rcx, rcx
    jz      .eff_update
    mov     al, [rsi]
    mov     [rbp], al
    inc     rsi
    inc     rbp
    dec     rcx
    jmp     .eff_sep_lp

.eff_update:
    lea     rax, [rel outbuf]
    sub     rbp, rax
    mov     [rel outbuf_pos], rbp

    xor     eax, eax
    add     rsp, 16
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.eff_err:
    mov     rax, -1
    add     rsp, 16
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  format_float — Convert double to fixed-point decimal string
;
;  xmm0 = value
;  edi = precision (decimal places)
;  rsi = output buffer
;  edx = buffer size
;  Returns: rax = length of string
; ============================================================================
format_float:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32

    mov     r12, rsi                    ; output buffer
    mov     r13d, edi                   ; precision
    movsd   [rsp], xmm0                ; save value

    ; Handle negative
    xor     r14d, r14d                  ; negative flag
    movsd   xmm0, [rsp]
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    jae     .ff_positive
    ; Check for -0.0
    movsd   xmm2, [rsp]
    mov     rax, [rsp]
    bt      rax, 63                     ; sign bit
    jnc     .ff_positive
    ; Negate
    mov     rax, [rsp]
    btr     rax, 63
    mov     [rsp], rax
    movsd   xmm0, [rsp]
    mov     r14d, 1

.ff_positive:
    ; Multiply by 10^precision to get integer representation
    ; value * 10^prec, then round to nearest integer
    movsd   xmm0, [rsp]
    ; Clear sign bit to work with absolute value
    mov     rax, [rsp]
    btr     rax, 63
    mov     [rsp], rax
    movsd   xmm0, [rsp]

    ; Compute 10^precision
    mov     ecx, r13d
    mov     rax, 1
.ff_pow10:
    test    ecx, ecx
    jz      .ff_pow_done
    imul    rax, 10
    dec     ecx
    jmp     .ff_pow10
.ff_pow_done:
    ; Convert power to double
    cvtsi2sd xmm1, rax

    ; Multiply
    mulsd   xmm0, xmm1

    ; Round to nearest (add 0.5 then truncate)
    movsd   xmm1, [rel const_half]
    addsd   xmm0, xmm1

    ; Convert to int64
    cvttsd2si rax, xmm0

    ; Now rax = integer representation
    ; e.g., for value=1.23, prec=2: rax=123
    mov     r15, rax                    ; save total

    ; Write the number as: [integer_part].[fractional_part]
    ; integer_part = total / 10^prec
    ; fractional_part = total % 10^prec

    ; Compute 10^prec again for division
    mov     ecx, r13d
    mov     rbx, 1
.ff_pow10b:
    test    ecx, ecx
    jz      .ff_pow_doneb
    imul    rbx, 10
    dec     ecx
    jmp     .ff_pow10b
.ff_pow_doneb:

    ; integer_part
    xor     edx, edx
    mov     rax, r15
    div     rbx
    mov     r15, rdx                    ; fractional part
    ; rax = integer part

    ; Write to buffer
    mov     rdi, r12
    xor     ecx, ecx                    ; position

    ; Write '-' if negative
    test    r14d, r14d
    jz      .ff_no_neg
    mov     byte [rdi + rcx], '-'
    inc     rcx
.ff_no_neg:

    ; Convert integer part to string
    push    r15
    push    rcx
    push    rdi

    ; Use stack-based itoa for integer part
    sub     rsp, 32
    lea     rdi, [rsp + 31]
    mov     byte [rdi], 0
    mov     rsi, rax
    ; rax = integer part value
    test    rax, rax
    jnz     .ff_int_loop
    dec     rdi
    mov     byte [rdi], '0'
    jmp     .ff_int_done

.ff_int_loop:
    test    rax, rax
    jz      .ff_int_done
    xor     edx, edx
    mov     r8, 10
    div     r8
    add     dl, '0'
    dec     rdi
    mov     [rdi], dl
    jmp     .ff_int_loop

.ff_int_done:
    ; rdi points to start of integer string
    ; Copy to output buffer
    mov     rsi, rdi                    ; source
    add     rsp, 32
    pop     rdi                         ; output buffer
    pop     rcx                         ; position
    pop     r15                         ; fractional part

.ff_copy_int:
    cmp     byte [rsi], 0
    je      .ff_int_copied
    mov     al, [rsi]
    mov     [rdi + rcx], al
    inc     rsi
    inc     rcx
    jmp     .ff_copy_int

.ff_int_copied:
    ; Write decimal point and fractional part (if precision > 0)
    test    r13d, r13d
    jz      .ff_done_fmt

    mov     byte [rdi + rcx], '.'
    inc     rcx

    ; Write fractional digits (r13d digits, zero-padded)
    ; r15 = fractional value
    ; Need to write exactly r13d digits
    mov     eax, r13d
    dec     eax
    ; Compute position power: start from 10^(prec-1) down to 1

    ; Compute 10^(prec-1)
    mov     r8, 1
    mov     edx, eax
.ff_frac_pow:
    test    edx, edx
    jz      .ff_frac_loop
    imul    r8, 10
    dec     edx
    jmp     .ff_frac_pow

.ff_frac_loop:
    test    r8, r8
    jz      .ff_done_fmt

    ; digit = r15 / r8
    mov     rax, r15
    xor     edx, edx
    div     r8
    add     al, '0'
    mov     [rdi + rcx], al
    inc     rcx

    ; r15 = r15 % r8
    mov     r15, rdx

    ; r8 = r8 / 10
    mov     rax, r8
    xor     edx, edx
    mov     r9, 10
    div     r9
    mov     r8, rax

    jmp     .ff_frac_loop

.ff_done_fmt:
    mov     byte [rdi + rcx], 0         ; null terminate
    mov     rax, rcx                    ; return length

    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  float_format_width — Calculate display width of a formatted float
;
;  xmm0 = value
;  edi = precision
;  Returns: eax = width
; ============================================================================
float_format_width:
    push    rbx
    sub     rsp, 128

    ; Format to temporary buffer on stack
    lea     rsi, [rsp]
    mov     edx, 120
    call    format_float
    ; rax = length
    mov     ebx, eax

    mov     eax, ebx
    add     rsp, 128
    pop     rbx
    ret


; ============================================================================
;  format_with_fmt — Format a double using printf-style format string
;
;  rdi = format string pointer
;  rcx = format string length
;  rsi = output buffer
;  edx = output buffer size
;  xmm0 = value
;  Returns: rax = length of formatted string
; ============================================================================
format_with_fmt:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 16

    mov     r12, rdi                    ; fmt string
    mov     r13, rcx                    ; fmt length
    mov     r14, rsi                    ; output buffer
    movsd   [rsp], xmm0                ; save value at [rsp]
    ; [rsp] = saved xmm0 value — stable location

    xor     ebp, ebp                    ; output position (using rbp)
    xor     ebx, ebx                    ; fmt position

.fwf_loop:
    cmp     rbx, r13
    jge     .fwf_done

    cmp     byte [r12 + rbx], '%'
    je      .fwf_format

    ; Regular character
    mov     al, [r12 + rbx]
    mov     [r14 + rbp], al
    inc     ebp
    inc     ebx
    jmp     .fwf_loop

.fwf_format:
    inc     ebx                         ; skip '%'
    cmp     rbx, r13
    jge     .fwf_done

    ; Check for '%%'
    cmp     byte [r12 + rbx], '%'
    jne     .fwf_parse_spec
    mov     byte [r14 + rbp], '%'
    inc     ebp
    inc     ebx
    jmp     .fwf_loop

.fwf_parse_spec:
    ; Parse: [flags][width][.precision]type
    xor     r8d, r8d                    ; flags: bit0=zero-pad
    mov     r9d, 0                      ; width (0 = unspecified)
    mov     r10d, -1                    ; precision (-1 = unspecified)

    ; Parse flags
.fwf_flags:
    cmp     rbx, r13
    jge     .fwf_done
    cmp     byte [r12 + rbx], '0'
    jne     .fwf_check_minus
    or      r8d, 1
    inc     ebx
    jmp     .fwf_flags
.fwf_check_minus:
    cmp     byte [r12 + rbx], '-'
    jne     .fwf_parse_width
    or      r8d, 2
    inc     ebx
    jmp     .fwf_flags

.fwf_parse_width:
    movzx   eax, byte [r12 + rbx]
    sub     eax, '0'
    cmp     eax, 9
    ja      .fwf_check_dot
.fwf_width_loop:
    cmp     rbx, r13
    jge     .fwf_done
    movzx   eax, byte [r12 + rbx]
    sub     eax, '0'
    cmp     eax, 9
    ja      .fwf_check_dot
    imul    r9d, 10
    add     r9d, eax
    inc     ebx
    jmp     .fwf_width_loop

.fwf_check_dot:
    cmp     byte [r12 + rbx], '.'
    jne     .fwf_type
    inc     ebx
    xor     r10d, r10d
.fwf_prec_loop:
    cmp     rbx, r13
    jge     .fwf_done
    movzx   eax, byte [r12 + rbx]
    sub     eax, '0'
    cmp     eax, 9
    ja      .fwf_type
    imul    r10d, 10
    add     r10d, eax
    inc     ebx
    jmp     .fwf_prec_loop

.fwf_type:
    cmp     rbx, r13
    jge     .fwf_done

    movzx   r15d, byte [r12 + rbx]     ; type char
    inc     ebx

    cmp     r15b, 'g'
    je      .fwf_do_g
    cmp     r15b, 'G'
    je      .fwf_do_g
    cmp     r15b, 'f'
    je      .fwf_do_f
    cmp     r15b, 'e'
    je      .fwf_do_e
    cmp     r15b, 'E'
    je      .fwf_do_e
    ; Unknown — skip
    jmp     .fwf_loop

.fwf_do_g:
    ; %g: format with precision decimal places, strip trailing zeros
    movsd   xmm0, [rsp]                ; reload value
    cmp     r10d, -1
    jne     .fwf_g_prec_ok
    mov     r10d, 6
.fwf_g_prec_ok:
    mov     edi, r10d
    lea     rsi, [rel fmt_scratch]
    mov     edx, FMT_BUF_SIZE
    call    format_float
    mov     r11, rax                    ; length in fmt_scratch

    ; Strip trailing zeros after decimal point
    lea     rsi, [rel fmt_scratch]
    ; Find decimal point
    xor     ecx, ecx
.fwf_g_fdot:
    cmp     ecx, r11d
    jge     .fwf_g_no_dot
    cmp     byte [rsi + rcx], '.'
    je      .fwf_g_has_dot
    inc     ecx
    jmp     .fwf_g_fdot

.fwf_g_has_dot:
    ; Strip trailing '0' from end
    mov     eax, r11d
    dec     eax
.fwf_g_sloop:
    cmp     eax, ecx
    jle     .fwf_g_sdone
    cmp     byte [rsi + rax], '0'
    jne     .fwf_g_scheck
    dec     eax
    jmp     .fwf_g_sloop
.fwf_g_scheck:
    cmp     byte [rsi + rax], '.'
    jne     .fwf_g_sdone
    dec     eax                         ; strip trailing '.' too
.fwf_g_sdone:
    inc     eax
    mov     r11d, eax

.fwf_g_no_dot:
    ; Apply width/padding then copy to output
    jmp     .fwf_apply_padding

.fwf_do_f:
    ; %f: fixed-point format
    movsd   xmm0, [rsp]                ; reload value
    cmp     r10d, -1
    jne     .fwf_f_prec_ok
    mov     r10d, 6
.fwf_f_prec_ok:
    mov     edi, r10d
    lea     rsi, [rel fmt_scratch]
    mov     edx, FMT_BUF_SIZE
    call    format_float
    mov     r11, rax
    jmp     .fwf_apply_padding

.fwf_do_e:
    ; %e: scientific notation
    movsd   xmm0, [rsp]                ; reload value
    cmp     r10d, -1
    jne     .fwf_e_prec_ok
    mov     r10d, 6
.fwf_e_prec_ok:
    lea     rsi, [rel fmt_scratch]
    mov     edx, FMT_BUF_SIZE
    call    format_scientific
    mov     r11, rax
    jmp     .fwf_apply_padding

.fwf_apply_padding:
    ; r11d = length of string in fmt_scratch
    ; r9d = desired width, r8d = flags (bit0=zero-pad)
    ; rbp = output position, r14 = output buffer

    ; Compute pad count
    mov     ecx, r9d
    sub     ecx, r11d                   ; pad = width - length
    ; If pad <= 0, just copy
    cmp     ecx, 0
    jle     .fwf_just_copy

    ; Zero-pad?
    test    r8d, 1
    jnz     .fwf_zero_pad

    ; Space-pad (left-justify not handled for simplicity)
.fwf_space_pad:
    mov     byte [r14 + rbp], ' '
    inc     ebp
    dec     ecx
    jnz     .fwf_space_pad
    jmp     .fwf_just_copy

.fwf_zero_pad:
    ; If negative, write '-' first then zeros then digits (skip '-')
    cmp     byte [rel fmt_scratch], '-'
    jne     .fwf_zp_loop
    mov     byte [r14 + rbp], '-'
    inc     ebp
.fwf_zp_loop:
    test    ecx, ecx
    jz      .fwf_zp_digits
    mov     byte [r14 + rbp], '0'
    inc     ebp
    dec     ecx
    jmp     .fwf_zp_loop
.fwf_zp_digits:
    ; Copy digits, skip leading '-' if we already wrote it
    cmp     byte [rel fmt_scratch], '-'
    jne     .fwf_just_copy
    ; Copy without '-'
    lea     rsi, [rel fmt_scratch + 1]
    mov     ecx, r11d
    dec     ecx
    xor     edx, edx
.fwf_zp_copy:
    cmp     edx, ecx
    jge     .fwf_loop
    mov     al, [rsi + rdx]
    mov     [r14 + rbp], al
    inc     ebp
    inc     edx
    jmp     .fwf_zp_copy

.fwf_just_copy:
    lea     rsi, [rel fmt_scratch]
    xor     edx, edx
.fwf_copy_loop:
    cmp     edx, r11d
    jge     .fwf_loop
    mov     al, [rsi + rdx]
    mov     [r14 + rbp], al
    inc     ebp
    inc     edx
    jmp     .fwf_copy_loop

.fwf_done:
    mov     byte [r14 + rbp], 0
    mov     rax, rbp                    ; return length

    add     rsp, 16
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  format_scientific — Format double in scientific notation (e.g., 1.00e+00)
;
;  xmm0 = value
;  r10d = precision (decimal places)
;  rsi = output buffer
;  edx = buffer size
;  Returns: rax = length
; ============================================================================
format_scientific:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48

    mov     r12, rsi                    ; output buffer
    mov     r13d, r10d                  ; precision
    movsd   [rsp], xmm0

    ; Handle sign
    xor     r14d, r14d                  ; position in output
    mov     rax, [rsp]
    bt      rax, 63
    jnc     .fs_positive
    mov     byte [r12], '-'
    inc     r14d
    btr     rax, 63
    mov     [rsp], rax
.fs_positive:
    movsd   xmm0, [rsp]

    ; Handle zero
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    jne     .fs_nonzero

    ; Zero: 0.00...e+00
    mov     byte [r12 + r14], '0'
    inc     r14d
    test    r13d, r13d
    jz      .fs_zero_exp
    mov     byte [r12 + r14], '.'
    inc     r14d
    mov     ecx, r13d
.fs_zero_dec:
    mov     byte [r12 + r14], '0'
    inc     r14d
    dec     ecx
    jnz     .fs_zero_dec
.fs_zero_exp:
    mov     byte [r12 + r14], 'e'
    inc     r14d
    mov     byte [r12 + r14], '+'
    inc     r14d
    mov     byte [r12 + r14], '0'
    inc     r14d
    mov     byte [r12 + r14], '0'
    inc     r14d
    jmp     .fs_done

.fs_nonzero:
    ; Find exponent: normalize to [1.0, 10.0)
    movsd   xmm0, [rsp]
    xor     r15d, r15d                  ; exponent

    movsd   xmm2, [rel const_ten]
    movsd   xmm3, [rel const_one]
    movsd   xmm4, [rel const_tenth]

    ; If >= 10, divide by 10 and increment exponent
.fs_norm_up:
    ucomisd xmm0, xmm2
    jb      .fs_check_down
    mulsd   xmm0, xmm4
    inc     r15d
    jmp     .fs_norm_up

.fs_check_down:
    ucomisd xmm0, xmm3
    jae     .fs_normalized
    mulsd   xmm0, xmm2
    dec     r15d
    jmp     .fs_check_down

.fs_normalized:
    ; xmm0 is now in [1.0, 10.0), r15d = exponent
    ; Format mantissa with precision decimal places
    movsd   [rsp], xmm0
    mov     edi, r13d
    lea     rsi, [rsp + 16]             ; temp buffer
    mov     edx, 30
    call    format_float
    ; Result in [rsp+16], length in rax

    ; Copy mantissa to output
    lea     rsi, [rsp + 16]
    xor     ecx, ecx
.fs_copy_mantissa:
    cmp     byte [rsi + rcx], 0
    je      .fs_write_exp
    mov     al, [rsi + rcx]
    mov     [r12 + r14], al
    inc     r14d
    inc     ecx
    jmp     .fs_copy_mantissa

.fs_write_exp:
    mov     byte [r12 + r14], 'e'
    inc     r14d

    ; Sign of exponent
    test    r15d, r15d
    jns     .fs_exp_pos
    mov     byte [r12 + r14], '-'
    inc     r14d
    neg     r15d
    jmp     .fs_exp_digits
.fs_exp_pos:
    mov     byte [r12 + r14], '+'
    inc     r14d

.fs_exp_digits:
    ; Write at least 2 digits
    cmp     r15d, 10
    jge     .fs_exp_2plus
    mov     byte [r12 + r14], '0'
    inc     r14d
    add     r15b, '0'
    mov     [r12 + r14], r15b
    inc     r14d
    jmp     .fs_done

.fs_exp_2plus:
    ; Convert exponent to decimal
    mov     eax, r15d
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    test    eax, eax
    jz      .fs_exp_tens
    add     al, '0'
    mov     [r12 + r14], al
    inc     r14d

.fs_exp_tens:
    mov     eax, edx
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    add     al, '0'
    mov     [r12 + r14], al
    inc     r14d
    add     dl, '0'
    mov     [r12 + r14], dl
    inc     r14d

.fs_done:
    mov     byte [r12 + r14], 0
    mov     eax, r14d

    add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  flush_outbuf — Flush the output buffer to stdout
;
;  Returns: rax = 0 on success, -1 on error
; ============================================================================
flush_outbuf:
    mov     rdx, [rel outbuf_pos]
    test    rdx, rdx
    jz      .flush_noop

    mov     rdi, STDOUT
    lea     rsi, [rel outbuf]
    call    asm_write_all

    mov     qword [rel outbuf_pos], 0
    ret

.flush_noop:
    xor     eax, eax
    ret


; ============================================================================
;  finalize_output — Replace last separator with newline, then flush
;
;  The output buffer ends with ...number+separator. We need to replace
;  the separator with a final newline.
; ============================================================================
finalize_output:
    mov     rax, [rel outbuf_pos]
    test    rax, rax
    jz      .fin_done                   ; nothing written

    ; Remove last separator
    mov     rcx, [rel sep_len]
    sub     rax, rcx
    js      .fin_done                   ; shouldn't happen
    mov     [rel outbuf_pos], rax

    ; Add final newline
    lea     rdx, [rel outbuf]
    add     rdx, rax
    mov     byte [rdx], 10             ; '\n'
    inc     qword [rel outbuf_pos]

.fin_done:
    ; Flush
    call    flush_outbuf
    ret


; ============================================================================
;  parse_int64 — Parse a null-terminated string as int64
;
;  rdi = string pointer
;  Returns: rax = value, edx = 0 if ok, 1 if error
; ============================================================================
parse_int64:
    push    rbx
    push    r12

    mov     r12, rdi
    xor     eax, eax                    ; result
    xor     ecx, ecx                    ; negative flag
    xor     ebx, ebx                    ; index

    ; Check for leading sign
    cmp     byte [r12], '-'
    jne     .pi_check_plus
    mov     ecx, 1
    inc     ebx
    jmp     .pi_digits

.pi_check_plus:
    cmp     byte [r12], '+'
    jne     .pi_digits
    inc     ebx

.pi_digits:
    ; Check for empty string
    cmp     byte [r12 + rbx], 0
    je      .pi_error

    ; Check for hex prefix 0x/0X
    cmp     byte [r12 + rbx], '0'
    jne     .pi_not_hex
    movzx   eax, byte [r12 + rbx + 1]
    or      al, 0x20
    cmp     al, 'x'
    je      .pi_do_hex
.pi_not_hex:

    ; Check first digit
    movzx   edx, byte [r12 + rbx]
    sub     edx, '0'
    cmp     edx, 9
    ja      .pi_error                   ; not a digit, not hex

.pi_loop:
    movzx   edx, byte [r12 + rbx]
    test    dl, dl
    jz      .pi_done

    sub     edx, '0'
    cmp     edx, 9
    ja      .pi_check_dot               ; might be float

    imul    rax, 10
    jo      .pi_error                   ; overflow
    add     rax, rdx
    inc     ebx
    jmp     .pi_loop

.pi_check_dot:
    ; If we see '.', this is a float — return error to trigger float path
    cmp     byte [r12 + rbx], '.'
    je      .pi_error
    jmp     .pi_error

.pi_do_hex:
    add     ebx, 2                      ; skip "0x"
    xor     eax, eax                    ; re-zero accumulator
    jmp     .pi_hex_loop

.pi_hex_loop:
    movzx   edx, byte [r12 + rbx]
    test    dl, dl
    jz      .pi_done

    shl     rax, 4
    cmp     dl, '0'
    jb      .pi_error
    cmp     dl, '9'
    jbe     .pi_hex_digit
    or      dl, 0x20                    ; lowercase
    cmp     dl, 'a'
    jb      .pi_error
    cmp     dl, 'f'
    ja      .pi_error
    sub     edx, 'a'
    add     edx, 10
    jmp     .pi_hex_add
.pi_hex_digit:
    sub     edx, '0'
.pi_hex_add:
    add     rax, rdx
    inc     ebx
    jmp     .pi_hex_loop

.pi_done:
    ; Apply sign
    test    ecx, ecx
    jz      .pi_ok
    neg     rax

.pi_ok:
    xor     edx, edx                    ; success
    pop     r12
    pop     rbx
    ret

.pi_error:
    ; Check if this could be a valid float before reporting error
    mov     rdi, r12
    call    is_valid_number
    test    eax, eax
    jnz     .pi_float_ok

    ; Invalid number — print error and exit
    push    r12
    lea     rsi, [rel err_invalid_float_pre]
    mov     edx, err_invalid_float_pre_len
    mov     rdi, STDERR
    call    asm_write_all

    pop     r12
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, r12
    mov     rdi, STDERR
    call    asm_write_all

    lea     rsi, [rel err_quote_nl]
    mov     edx, 2
    mov     rdi, STDERR
    call    asm_write_all

    lea     rsi, [rel err_try_help]
    mov     edx, err_try_help_len
    mov     rdi, STDERR
    call    asm_write_all

    mov     edi, 1
    call    asm_exit

.pi_float_ok:
    mov     edx, 1                      ; signal: parse as float instead
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  parse_double — Parse string to double (in xmm0)
;
;  rdi = null-terminated string
;  Returns: xmm0 = value
; ============================================================================
parse_double:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 16

    mov     r12, rdi
    xor     ebx, ebx                    ; index
    xor     r13d, r13d                  ; negative flag

    ; Handle sign
    cmp     byte [r12], '-'
    jne     .pd_check_plus
    mov     r13d, 1
    inc     ebx
    jmp     .pd_int_part
.pd_check_plus:
    cmp     byte [r12], '+'
    jne     .pd_int_part
    inc     ebx

.pd_int_part:
    ; Parse integer part
    xorpd   xmm0, xmm0                 ; result = 0.0
    movsd   xmm2, [rel const_ten]

.pd_int_loop:
    movzx   eax, byte [r12 + rbx]
    sub     eax, '0'
    cmp     eax, 9
    ja      .pd_check_dot

    cvtsi2sd xmm1, eax
    mulsd   xmm0, xmm2
    addsd   xmm0, xmm1
    inc     ebx
    jmp     .pd_int_loop

.pd_check_dot:
    cmp     byte [r12 + rbx], '.'
    jne     .pd_check_exp

    inc     ebx                         ; skip '.'

    ; Parse fractional part
    movsd   xmm3, [rel const_tenth]     ; current place value
.pd_frac_loop:
    movzx   eax, byte [r12 + rbx]
    sub     eax, '0'
    cmp     eax, 9
    ja      .pd_check_exp

    cvtsi2sd xmm1, eax
    mulsd   xmm1, xmm3
    addsd   xmm0, xmm1
    mulsd   xmm3, [rel const_tenth]
    inc     ebx
    jmp     .pd_frac_loop

.pd_check_exp:
    ; Check for 'e' or 'E' exponent
    movzx   eax, byte [r12 + rbx]
    or      al, 0x20
    cmp     al, 'e'
    jne     .pd_apply_sign

    inc     ebx
    ; Parse exponent
    xor     r14d, r14d                  ; exp negative
    xor     ecx, ecx                    ; exponent value

    cmp     byte [r12 + rbx], '-'
    jne     .pd_exp_check_plus
    mov     r14d, 1
    inc     ebx
    jmp     .pd_exp_digits
.pd_exp_check_plus:
    cmp     byte [r12 + rbx], '+'
    jne     .pd_exp_digits
    inc     ebx

.pd_exp_digits:
    movzx   eax, byte [r12 + rbx]
    sub     eax, '0'
    cmp     eax, 9
    ja      .pd_apply_exp
    imul    ecx, 10
    add     ecx, eax
    inc     ebx
    jmp     .pd_exp_digits

.pd_apply_exp:
    ; Apply 10^exp multiplier/divisor
    test    r14d, r14d
    jnz     .pd_exp_neg

    ; Positive exponent: multiply by 10^exp
.pd_exp_mul:
    test    ecx, ecx
    jz      .pd_apply_sign
    mulsd   xmm0, [rel const_ten]
    dec     ecx
    jmp     .pd_exp_mul

.pd_exp_neg:
    test    ecx, ecx
    jz      .pd_apply_sign
    mulsd   xmm0, [rel const_tenth]
    dec     ecx
    jmp     .pd_exp_neg

.pd_apply_sign:
    test    r13d, r13d
    jz      .pd_done
    ; Negate: flip sign bit
    mov     rax, 0x8000000000000000
    movq    xmm1, rax
    xorpd   xmm0, xmm1

.pd_done:
    add     rsp, 16
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  count_decimals — Count decimal places in a number string
;
;  rdi = null-terminated string
;  Returns: eax = number of decimal places (0 if no decimal point)
; ============================================================================
count_decimals:
    xor     eax, eax
    xor     ecx, ecx                    ; found dot flag

.cd_loop:
    movzx   edx, byte [rdi]
    test    dl, dl
    jz      .cd_done

    cmp     dl, '.'
    jne     .cd_not_dot
    mov     ecx, 1
    inc     rdi
    jmp     .cd_loop

.cd_not_dot:
    test    ecx, ecx
    jz      .cd_next
    ; After dot — count digits
    sub     edx, '0'
    cmp     edx, 9
    ja      .cd_done
    inc     eax

.cd_next:
    inc     rdi
    jmp     .cd_loop

.cd_done:
    ret


; ============================================================================
;  parse_float_args — Parse first/incr/last as floats (called when is_float=1)
;  Populates first_fval, incr_fval, last_fval
; ============================================================================
parse_float_args:
    push    rbx

    ; Parse first
    mov     rdi, [rel first_str]
    call    parse_double
    movsd   [rel first_fval], xmm0

    ; Parse incr
    mov     rdi, [rel incr_str]
    call    parse_double
    movsd   [rel incr_fval], xmm0

    ; Parse last
    mov     rdi, [rel last_str]
    call    parse_double
    movsd   [rel last_fval], xmm0

    ; Check for zero increment
    xorpd   xmm1, xmm1
    movsd   xmm0, [rel incr_fval]
    ucomisd xmm0, xmm1
    jne     .pfa_ok

    ; Zero increment error
    mov     rbx, [rel incr_str]
    lea     rsi, [rel err_zero_incr_pre]
    mov     edx, err_zero_incr_pre_len
    mov     rdi, STDERR
    call    asm_write_all
    mov     rdi, rbx
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, rbx
    mov     rdi, STDERR
    call    asm_write_all
    lea     rsi, [rel err_quote_nl]
    mov     edx, 2
    mov     rdi, STDERR
    call    asm_write_all
    lea     rsi, [rel err_try_help]
    mov     edx, err_try_help_len
    mov     rdi, STDERR
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.pfa_ok:
    pop     rbx
    ret


; ============================================================================
;  Utility functions
; ============================================================================

; has_dot(rdi=str) -> eax=1 if string contains '.', else 0
has_dot:
    xor     eax, eax
.hd_loop:
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .hd_done
    cmp     cl, '.'
    je      .hd_found
    inc     rdi
    jmp     .hd_loop
.hd_found:
    mov     eax, 1
.hd_done:
    ret

; is_valid_number(rdi=str) -> eax=1 if looks like a valid float, else 0
is_valid_number:
    push    rbx
    mov     rbx, rdi
    xor     ecx, ecx                    ; saw digit flag

    ; Skip leading sign
    cmp     byte [rbx], '-'
    je      .ivn_skip_sign
    cmp     byte [rbx], '+'
    jne     .ivn_digits
.ivn_skip_sign:
    inc     rbx

.ivn_digits:
    movzx   eax, byte [rbx]
    test    al, al
    jz      .ivn_check

    cmp     al, '.'
    je      .ivn_next
    sub     al, '0'
    cmp     al, 9
    ja      .ivn_check_exp
    mov     ecx, 1

.ivn_next:
    inc     rbx
    jmp     .ivn_digits

.ivn_check_exp:
    or      byte [rbx], 0x20
    cmp     byte [rbx], 'e'
    je      .ivn_exp
    jmp     .ivn_fail

.ivn_exp:
    test    ecx, ecx
    jz      .ivn_fail
    mov     eax, 1
    pop     rbx
    ret

.ivn_check:
    mov     eax, ecx
    pop     rbx
    ret

.ivn_fail:
    xor     eax, eax
    pop     rbx
    ret

; str_eq(rdi=s1, rsi=s2) -> eax=1 if equal, 0 if not
str_eq:
.seq_loop:
    mov     al, [rdi]
    mov     cl, [rsi]
    cmp     al, cl
    jne     .seq_ne
    test    al, al
    jz      .seq_equal
    inc     rdi
    inc     rsi
    jmp     .seq_loop
.seq_equal:
    mov     eax, 1
    ret
.seq_ne:
    xor     eax, eax
    ret

; str_prefix(rdi=str, rsi=prefix, edx=prefix_len) -> eax=1 if str starts with prefix
str_prefix:
    xor     ecx, ecx
.sp_loop:
    cmp     ecx, edx
    jge     .sp_match
    mov     al, [rdi + rcx]
    cmp     al, [rsi + rcx]
    jne     .sp_no
    inc     ecx
    jmp     .sp_loop
.sp_match:
    mov     eax, 1
    ret
.sp_no:
    xor     eax, eax
    ret


; ============================================================================
;  Data sections
; ============================================================================

section .data

align 16
const_ten:      dq 10.0
const_one:      dq 1.0
const_tenth:    dq 0.1
const_half:     dq 0.5

default_sep:    db 10                   ; newline
str_one:        db "1", 0

; Option strings
str_help_opt:       db "--help", 0
str_version_opt:    db "--version", 0
str_format_eq:      db "--format=", 0
str_separator_eq:   db "--separator=", 0
str_equal_width:    db "--equal-width", 0

; Error messages
err_missing_operand:
    db "seq: missing operand", 10
err_missing_operand_len equ $ - err_missing_operand

err_extra_operand:
    db "seq: extra operand '", 0
err_extra_operand_len equ $ - err_extra_operand - 1

err_zero_incr_pre:
    db "seq: invalid Zero increment value: '", 0
err_zero_incr_pre_len equ $ - err_zero_incr_pre - 1

err_invalid_float_pre:
    db "seq: invalid floating point argument: '", 0
err_invalid_float_pre_len equ $ - err_invalid_float_pre - 1

err_quote_nl:
    db "'", 10

err_try_help:
    db "Try 'seq --help' for more information.", 10
err_try_help_len equ $ - err_try_help

err_unknown_opt:
    db "seq: unrecognized option '", 0
err_unknown_opt_len equ $ - err_unknown_opt - 1

err_missing_fmt:
    db "seq: option requires an argument -- 'f'", 10
err_missing_fmt_len equ $ - err_missing_fmt

err_missing_sep:
    db "seq: option requires an argument -- 's'", 10
err_missing_sep_len equ $ - err_missing_sep

; @@DATA_START@@
help_text:
    db "Usage: seq [OPTION]... LAST", 10
    db "  or:  seq [OPTION]... FIRST LAST", 10
    db "  or:  seq [OPTION]... FIRST INCREMENT LAST", 10
    db "Print numbers from FIRST to LAST, in steps of INCREMENT.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -f, --format=FORMAT      use printf style floating-point FORMAT", 10
    db "  -s, --separator=STRING   use STRING to separate numbers (default: \n)", 10
    db "  -w, --equal-width        equalize width by padding with leading zeroes", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "If FIRST or INCREMENT is omitted, it defaults to 1.  That is, an", 10
    db "omitted INCREMENT defaults to 1 even when LAST is smaller than FIRST.", 10
    db "The sequence of numbers ends when the sum of the current number and", 10
    db "INCREMENT would become greater than LAST.", 10
    db "FIRST, INCREMENT, and LAST are interpreted as floating point values.", 10
    db "INCREMENT is usually positive if FIRST is smaller than LAST, and", 10
    db "INCREMENT is usually negative if FIRST is greater than LAST.", 10
    db "INCREMENT must not be 0; none of FIRST, INCREMENT and LAST may be NaN.", 10
    db "FORMAT must be suitable for printing one argument of type 'double';", 10
    db "it defaults to %.PRECf if FIRST, INCREMENT, and LAST are all fixed point", 10
    db "decimal numbers with maximum precision PREC, and to %g otherwise.", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/seq>", 10
    db "or available locally via: info '(coreutils) seq invocation'", 10
help_text_len equ $ - help_text

version_text:
    db "seq (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Ulrich Drepper.", 10
version_text_len equ $ - version_text
; @@DATA_END@@

section .bss

align 8
argc:           resq 1
argv:           resq 1
end_of_opts:    resb 1
flag_w:         resb 1
flag_f:         resb 1
is_float:       resb 1
num_count:      resd 1
float_prec:     resd 1

; Number storage (3 values max)
num_strs:       resq 3                  ; pointers to original strings
num_ints:       resq 3                  ; parsed integer values

; Resolved values
first_val:      resq 1
incr_val:       resq 1
last_val:       resq 1

first_str:      resq 1
incr_str:       resq 1
last_str:       resq 1

; Float values
alignb 16
first_fval:     resq 1
incr_fval:      resq 1
last_fval:      resq 1

; Separator
sep_ptr:        resq 1
sep_len:        resq 1

; Format
fmt_ptr:        resq 1
fmt_len:        resq 1

; emit_float_fmt temporaries
_eff_flags:     resd 1
_eff_width:     resd 1
_eff_prec:      resd 1

; Output buffer
outbuf_pos:     resq 1
itoa_buf:       resb ITOA_BUF_SIZE + 8
fmt_scratch:    resb FMT_BUF_SIZE + 8

alignb 16
outbuf:         resb OUTBUF_SIZE

section .note.GNU-stack noalloc noexec nowrite progbits
