; ============================================================
; fexpr_unified.asm — GNU-compatible 'expr' command
; Builds with: nasm -f bin fexpr_unified.asm -o fexpr
;
; expr: Evaluate expressions.
; Supports: +, -, *, /, %, comparisons, |, &, string ops
;           length, substr, index, match, parentheses
; Exit: 0 if result is non-null/non-zero, 1 if null/zero, 2 on error
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE       1
%define SYS_EXIT       60
%define SYS_RT_SIGPROCMASK 14

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE         13

; BSS layout
%define BSS_BASE     0x500000
%define num_buf      BSS_BASE
%define result_buf   (num_buf + 128)
%define RESULT_MAX   4096
%define arg_idx      (result_buf + RESULT_MAX)
%define arg_max      (arg_idx + 8)
%define argv_ptr     (arg_max + 8)
%define BSS_END      (argv_ptr + 8)
%define BSS_SIZE     (BSS_END - BSS_BASE)

; --- ELF Header ---
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
    dd 1, 5
    dq 0, $$, $$, file_size, file_size, 0x200000

    dd 1, 6
    dq 0, BSS_BASE, BSS_BASE, 0, BSS_SIZE, 0x200000

    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 0x10

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

    mov     r14d, [rsp]         ; argc
    lea     r15, [rsp + 8]      ; argv

    cmp     r14d, 2
    jl      .err_missing

    ; Check --help / --version
    mov     rdi, [r15 + 8]
    push    r14
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .show_help
    mov     rdi, [r15 + 8]
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .show_version
    pop     r14

    ; Initialize parser state
    mov     qword [arg_idx], 1  ; start at argv[1]
    mov     rax, r14
    dec     rax                 ; arg_max = argc - 1
    mov     [arg_max], rax
    mov     [argv_ptr], r15

    ; Parse and evaluate expression
    call    eval_or

    ; Check if all args consumed
    mov     rbx, [arg_idx]
    cmp     ebx, r14d
    jl      .err_syntax

    ; Print result
    ; rax = result value (integer), r8 = 0 if numeric, 1 if string ptr
    test    r8d, r8d
    jnz     .print_string

    ; Print integer — save value first for exit code determination
    push    rax
    mov     rdi, rax
    call    print_int_result
    pop     rax
    ; rax has the original integer value
    test    rax, rax
    jz      .exit_1
    jmp     .exit_0

.print_string:
    ; rax = string pointer
    mov     r12, rax            ; save string pointer
    mov     rdi, rax
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    mov     edi, STDOUT
    call    do_write
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write
    ; Check if string is null/zero
    mov     rdi, r12
    call    str_len
    test    eax, eax
    jz      .exit_1             ; empty string = null
    ; Check if "0"
    cmp     byte [r12], '0'
    jne     .exit_0
    cmp     byte [r12 + 1], 0
    je      .exit_1
    jmp     .exit_0

.exit_0:
    xor     edi, edi
    jmp     do_exit
.exit_1:
    mov     edi, 1
    jmp     do_exit

.show_help:
    pop     r14
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.show_version:
    pop     r14
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.err_missing:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing
    mov     edx, str_missing_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 2
    jmp     do_exit

.err_syntax:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_syntax
    mov     edx, str_syntax_len
    call    do_write_err
    mov     edi, 2
    jmp     do_exit

; ============================================================
; Expression evaluator (recursive descent parser)
; Returns: rax = value, r8d = 0 if numeric, 1 if string
; ============================================================

; Get current arg (or NULL if past end)
get_arg:
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .ga_null
    mov     r15, [rsp + 8]      ; Can't use r15 directly anymore
    mov     rax, [argv_ptr]
    mov     rax, [rax + rcx*8]
    ret
.ga_null:
    xor     eax, eax
    ret

; Advance to next arg
next_arg:
    inc     qword [arg_idx]
    ret

; eval_or: handle '|' operator
eval_or:
    push    rbx
    push    r12
    push    r13
    call    eval_and
    mov     r12, rax            ; left value
    mov     r13d, r8d           ; left type

.or_loop:
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .or_done
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    cmp     byte [rdi], '|'
    jne     .or_done
    cmp     byte [rdi + 1], 0
    jne     .or_done

    call    next_arg
    push    r12
    push    r13
    call    eval_and
    pop     r13
    pop     r12

    ; If left is non-null/non-zero, return left
    test    r13d, r13d
    jnz     .or_check_str_left
    ; Left is numeric
    test    r12, r12
    jnz     .or_done            ; left is non-zero
    ; Left is zero, use right
    mov     r12, rax
    mov     r13d, r8d
    jmp     .or_loop

.or_check_str_left:
    ; Check if left string is non-empty
    mov     rdi, r12
    push    rax
    push    r8
    call    str_len
    pop     r8
    pop     rax
    test    eax, eax
    jnz     .or_done            ; left string non-empty, keep it
    mov     r12, rax
    mov     r13d, r8d
    jmp     .or_loop

.or_done:
    mov     rax, r12
    mov     r8d, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

; eval_and: handle '&' operator
eval_and:
    push    rbx
    push    r12
    push    r13
    call    eval_compare
    mov     r12, rax
    mov     r13d, r8d

.and_loop:
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .and_done
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    cmp     byte [rdi], '&'
    jne     .and_done
    cmp     byte [rdi + 1], 0
    jne     .and_done

    call    next_arg
    push    r12
    push    r13
    call    eval_compare
    pop     r13
    pop     r12

    ; Both must be non-null/non-zero, else return 0
    ; Check left
    test    r13d, r13d
    jnz     .and_check_str
    test    r12, r12
    jz      .and_zero
    ; Check right
    test    r8d, r8d
    jnz     .and_check_right_str
    test    rax, rax
    jz      .and_zero
    jmp     .and_loop

.and_check_str:
    mov     rdi, r12
    push    rax
    push    r8
    call    str_len
    pop     r8
    pop     rax
    test    eax, eax
    jz      .and_zero
    ; Check right
    test    r8d, r8d
    jnz     .and_check_right_str
    test    rax, rax
    jz      .and_zero
    jmp     .and_loop

.and_check_right_str:
    push    r12
    push    r13
    mov     rdi, rax
    call    str_len
    pop     r13
    pop     r12
    test    eax, eax
    jz      .and_zero
    jmp     .and_loop

.and_zero:
    xor     r12d, r12d
    xor     r13d, r13d          ; numeric 0

.and_done:
    mov     rax, r12
    mov     r8d, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

; eval_compare: handle comparison operators
eval_compare:
    push    rbx
    push    r12
    push    r13
    call    eval_add
    mov     r12, rax
    mov     r13d, r8d

    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .cmp_done

    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]

    ; Check for comparison operators: = != < <= > >=
    movzx   eax, byte [rdi]
    cmp     al, '='
    je      .cmp_eq_check
    cmp     al, '!'
    je      .cmp_ne_check
    cmp     al, '<'
    je      .cmp_lt_check
    cmp     al, '>'
    je      .cmp_gt_check
    jmp     .cmp_done

.cmp_eq_check:
    cmp     byte [rdi + 1], 0
    jne     .cmp_done
    call    next_arg
    call    eval_add
    ; Compare: r12 vs rax (both as integers if possible)
    push    rax
    push    r8
    mov     rdi, r12
    test    r13d, r13d
    jnz     .cmp_eq_str
    pop     r8
    pop     rbx
    test    r8d, r8d
    jnz     .cmp_eq_str2
    ; Both numeric
    cmp     r12, rbx
    je      .cmp_true
    jmp     .cmp_false

.cmp_eq_str:
    pop     r8
    pop     rbx
.cmp_eq_str2:
    ; String comparison using str_eq
    mov     rdi, r12
    mov     rsi, rbx
    test    r13d, r13d
    jz      .cmp_eq_left_num
    jmp     .cmp_str_compare_eq
.cmp_eq_left_num:
    ; Left is number, right might be string — compare as numbers
    cmp     r12, rbx
    je      .cmp_true
    jmp     .cmp_false
.cmp_str_compare_eq:
    call    str_eq
    test    eax, eax
    jnz     .cmp_true
    jmp     .cmp_false

.cmp_ne_check:
    cmp     byte [rdi + 1], '='
    jne     .cmp_done
    cmp     byte [rdi + 2], 0
    jne     .cmp_done
    call    next_arg
    call    eval_add
    ; r12 != rax ?
    test    r13d, r13d
    jnz     .cmp_ne_str
    test    r8d, r8d
    jnz     .cmp_ne_str
    cmp     r12, rax
    jne     .cmp_true
    jmp     .cmp_false
.cmp_ne_str:
    mov     rdi, r12
    mov     rsi, rax
    call    str_eq
    test    eax, eax
    jz      .cmp_true
    jmp     .cmp_false

.cmp_lt_check:
    cmp     byte [rdi + 1], '='
    je      .cmp_le_check
    cmp     byte [rdi + 1], 0
    jne     .cmp_done
    call    next_arg
    call    eval_add
    test    r13d, r13d
    jnz     .cmp_lt_str
    test    r8d, r8d
    jnz     .cmp_lt_str
    cmp     r12, rax
    jl      .cmp_true
    jmp     .cmp_false
.cmp_lt_str:
    mov     rdi, r12
    mov     rsi, rax
    call    str_cmp
    test    eax, eax
    js      .cmp_true
    jmp     .cmp_false

.cmp_le_check:
    cmp     byte [rdi + 2], 0
    jne     .cmp_done
    call    next_arg
    call    eval_add
    test    r13d, r13d
    jnz     .cmp_le_str
    test    r8d, r8d
    jnz     .cmp_le_str
    cmp     r12, rax
    jle     .cmp_true
    jmp     .cmp_false
.cmp_le_str:
    mov     rdi, r12
    mov     rsi, rax
    call    str_cmp
    test    eax, eax
    jle     .cmp_true
    jmp     .cmp_false

.cmp_gt_check:
    cmp     byte [rdi + 1], '='
    je      .cmp_ge_check
    cmp     byte [rdi + 1], 0
    jne     .cmp_done
    call    next_arg
    call    eval_add
    test    r13d, r13d
    jnz     .cmp_gt_str
    test    r8d, r8d
    jnz     .cmp_gt_str
    cmp     r12, rax
    jg      .cmp_true
    jmp     .cmp_false
.cmp_gt_str:
    mov     rdi, r12
    mov     rsi, rax
    call    str_cmp
    test    eax, eax
    jg      .cmp_true
    jmp     .cmp_false

.cmp_ge_check:
    cmp     byte [rdi + 2], 0
    jne     .cmp_done
    call    next_arg
    call    eval_add
    test    r13d, r13d
    jnz     .cmp_ge_str
    test    r8d, r8d
    jnz     .cmp_ge_str
    cmp     r12, rax
    jge     .cmp_true
    jmp     .cmp_false
.cmp_ge_str:
    mov     rdi, r12
    mov     rsi, rax
    call    str_cmp
    test    eax, eax
    jge     .cmp_true
    jmp     .cmp_false

.cmp_true:
    mov     r12, 1
    xor     r13d, r13d
    jmp     .cmp_done
.cmp_false:
    xor     r12d, r12d
    xor     r13d, r13d

.cmp_done:
    mov     rax, r12
    mov     r8d, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

; eval_add: handle + and - operators
eval_add:
    push    rbx
    push    r12
    push    r13
    call    eval_mul
    mov     r12, rax            ; left value
    mov     r13d, r8d

.add_loop:
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .add_done
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    movzx   eax, byte [rdi]
    cmp     byte [rdi + 1], 0
    jne     .add_done

    cmp     al, '+'
    je      .do_add
    cmp     al, '-'
    je      .do_sub
    jmp     .add_done

.do_add:
    call    next_arg
    call    eval_mul
    add     r12, rax
    xor     r13d, r13d
    jmp     .add_loop

.do_sub:
    call    next_arg
    call    eval_mul
    sub     r12, rax
    xor     r13d, r13d
    jmp     .add_loop

.add_done:
    mov     rax, r12
    mov     r8d, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

; eval_mul: handle *, /, % operators
eval_mul:
    push    rbx
    push    r12
    push    r13
    call    eval_primary
    mov     r12, rax
    mov     r13d, r8d

.mul_loop:
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .mul_done
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    movzx   eax, byte [rdi]
    cmp     byte [rdi + 1], 0
    jne     .mul_done

    cmp     al, '*'
    je      .do_mul
    cmp     al, '/'
    je      .do_div
    cmp     al, '%'
    je      .do_mod
    jmp     .mul_done

.do_mul:
    call    next_arg
    call    eval_primary
    imul    r12, rax
    xor     r13d, r13d
    jmp     .mul_loop

.do_div:
    call    next_arg
    call    eval_primary
    test    rax, rax
    jz      .div_zero
    mov     rcx, rax            ; divisor
    mov     rax, r12            ; dividend
    cqo
    idiv    rcx
    mov     r12, rax            ; quotient
    xor     r13d, r13d
    jmp     .mul_loop
.div_zero:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_divzero
    mov     edx, str_divzero_len
    call    do_write_err
    mov     edi, 2
    jmp     do_exit

.do_mod:
    call    next_arg
    call    eval_primary
    test    rax, rax
    jz      .div_zero
    mov     rcx, rax
    mov     rax, r12
    cqo
    idiv    rcx
    mov     r12, rdx
    xor     r13d, r13d
    jmp     .mul_loop

.mul_done:
    mov     rax, r12
    mov     r8d, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

; eval_primary: handle atoms, parentheses, string functions
eval_primary:
    push    rbx

    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .prim_err

    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]

    ; Check for '('
    cmp     byte [rdi], '('
    jne     .prim_check_length
    cmp     byte [rdi + 1], 0
    jne     .prim_check_length
    call    next_arg
    call    eval_or
    ; Expect ')'
    push    rax
    push    r8
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .prim_unmatched
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    cmp     byte [rdi], ')'
    jne     .prim_unmatched
    cmp     byte [rdi + 1], 0
    jne     .prim_unmatched
    call    next_arg
    pop     r8
    pop     rax
    pop     rbx
    ret

.prim_unmatched:
    pop     r8
    pop     rax
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_syntax
    mov     edx, str_syntax_len
    call    do_write_err
    mov     edi, 2
    jmp     do_exit

.prim_check_length:
    ; Check for "length" keyword
    push    rcx
    mov     rsi, str_length_kw
    call    str_eq
    test    eax, eax
    jnz     .prim_length
    pop     rcx

    ; Check for "substr" keyword
    mov     rdi, [rbx + rcx*8]
    push    rcx
    mov     rsi, str_substr_kw
    call    str_eq
    test    eax, eax
    jnz     .prim_substr
    pop     rcx

    ; Check for "index" keyword
    mov     rdi, [rbx + rcx*8]
    push    rcx
    mov     rsi, str_index_kw
    call    str_eq
    test    eax, eax
    jnz     .prim_index
    pop     rcx

    ; It's a plain value (number or string)
    mov     rdi, [rbx + rcx*8]
    call    next_arg
    ; Try to parse as integer
    call    try_parse_int
    pop     rbx
    ret

.prim_length:
    pop     rcx
    call    next_arg
    ; Next arg is the string
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .prim_err
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    call    next_arg
    call    str_len
    movsx   rax, eax
    xor     r8d, r8d
    pop     rbx
    ret

.prim_substr:
    pop     rcx
    call    next_arg
    ; substr STRING POS LENGTH
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .prim_err
    mov     rbx, [argv_ptr]
    mov     r9, [rbx + rcx*8]  ; string
    call    next_arg
    ; Get POS
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .prim_err
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    call    next_arg
    call    try_parse_int
    mov     r10, rax            ; pos (1-based)
    ; Get LENGTH
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .prim_err
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    call    next_arg
    call    try_parse_int
    mov     r11, rax            ; length
    ; Compute substring
    mov     rdi, r9
    push    r10
    push    r11
    call    str_len
    pop     r11
    pop     r10
    movsx   rcx, eax            ; rcx = string length
    ; if length <= 0 or pos < 1 or pos > strlen, return ""
    cmp     r11, 0
    jle     .substr_empty
    cmp     r10, 1
    jl      .substr_empty
    cmp     r10, rcx
    jg      .substr_empty
    ; Clamp length to remaining chars: remaining = strlen - (pos-1)
    dec     r10                 ; 0-based start
    mov     rax, rcx
    sub     rax, r10            ; rax = remaining chars
    cmp     r11, rax
    jle     .substr_len_ok
    mov     r11, rax            ; clamp length to remaining
.substr_len_ok:
    ; Copy r11 bytes from r9+r10 into result_buf
    lea     rsi, [r9 + r10]    ; source
    lea     rdi, [result_buf]  ; destination
    xor     ecx, ecx
.substr_copy:
    cmp     rcx, r11
    jge     .substr_copy_done
    movzx   eax, byte [rsi + rcx]
    mov     [rdi + rcx], al
    inc     rcx
    jmp     .substr_copy
.substr_copy_done:
    mov     byte [rdi + rcx], 0 ; null-terminate
    mov     rax, rdi            ; return pointer to result_buf
    mov     r8d, 1              ; string result
    pop     rbx
    ret

.substr_empty:
    mov     rax, str_empty
    mov     r8d, 1
    pop     rbx
    ret

.prim_index:
    pop     rcx
    call    next_arg
    ; index STRING CHARS
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .prim_err
    mov     rbx, [argv_ptr]
    mov     r9, [rbx + rcx*8]  ; string
    call    next_arg
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .prim_err
    mov     rbx, [argv_ptr]
    mov     r10, [rbx + rcx*8] ; chars
    call    next_arg
    ; Find first occurrence of any char in CHARS within STRING
    xor     r11d, r11d          ; position in string (0-based)
.idx_loop:
    movzx   eax, byte [r9 + r11]
    test    al, al
    jz      .idx_notfound
    ; Check if this char is in CHARS
    xor     ecx, ecx
.idx_char_loop:
    movzx   edx, byte [r10 + rcx]
    test    dl, dl
    jz      .idx_next
    cmp     al, dl
    je      .idx_found
    inc     ecx
    jmp     .idx_char_loop
.idx_next:
    inc     r11d
    jmp     .idx_loop
.idx_found:
    lea     eax, [r11d + 1]     ; 1-based
    movsx   rax, eax
    xor     r8d, r8d
    pop     rbx
    ret
.idx_notfound:
    xor     eax, eax
    xor     r8d, r8d
    pop     rbx
    ret

.prim_err:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_syntax
    mov     edx, str_syntax_len
    call    do_write_err
    mov     edi, 2
    jmp     do_exit

; ============================================================
; try_parse_int: try to parse string as integer
; Input: rdi = string
; Output: rax = value, r8d = 0 if numeric, 1 if string (rax=ptr)
; ============================================================
try_parse_int:
    push    rbx
    push    r12
    mov     r12, rdi            ; save string pointer
    xor     rax, rax
    xor     ebx, ebx            ; negative flag
    movzx   ecx, byte [rdi]

    ; Handle leading minus
    cmp     cl, '-'
    jne     .tpi_check_digit
    mov     ebx, 1
    inc     rdi
    movzx   ecx, byte [rdi]

.tpi_check_digit:
    cmp     cl, '0'
    jb      .tpi_string
    cmp     cl, '9'
    ja      .tpi_string

.tpi_loop:
    movzx   ecx, byte [rdi]
    cmp     cl, '0'
    jb      .tpi_end_digits
    cmp     cl, '9'
    ja      .tpi_end_digits
    imul    rax, 10
    sub     cl, '0'
    movzx   ecx, cl
    add     rax, rcx
    inc     rdi
    jmp     .tpi_loop

.tpi_end_digits:
    test    cl, cl
    jnz     .tpi_string         ; trailing non-digit chars
    test    ebx, ebx
    jz      .tpi_num_done
    neg     rax
.tpi_num_done:
    xor     r8d, r8d
    pop     r12
    pop     rbx
    ret

.tpi_string:
    mov     rax, r12
    mov     r8d, 1
    pop     r12
    pop     rbx
    ret

; ============================================================
; print_int_result: print signed integer and newline
; Input: rdi = value
; ============================================================
print_int_result:
    push    rbx
    push    rcx
    push    rdx
    mov     rax, rdi
    ; Handle negative
    test    rax, rax
    jns     .pir_positive
    neg     rax
    push    rax
    mov     edi, STDOUT
    mov     rsi, str_minus
    mov     edx, 1
    call    do_write
    pop     rax
.pir_positive:
    ; Convert to decimal
    lea     rbx, [num_buf + 63]
    mov     byte [rbx], 0
    mov     rcx, 10
    test    rax, rax
    jnz     .pir_loop
    dec     rbx
    mov     byte [rbx], '0'
    jmp     .pir_print
.pir_loop:
    test    rax, rax
    jz      .pir_print
    xor     edx, edx
    div     rcx
    add     dl, '0'
    dec     rbx
    mov     [rbx], dl
    jmp     .pir_loop
.pir_print:
    lea     edx, [num_buf + 63]
    sub     edx, ebx
    mov     rsi, rbx
    mov     edi, STDOUT
    call    do_write
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write
    pop     rdx
    pop     rcx
    pop     rbx
    ret

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

; str_cmp: compare two strings lexicographically
; Returns: eax < 0 if s1 < s2, 0 if equal, > 0 if s1 > s2
str_cmp:
    xor     r8d, r8d
.sc_loop:
    movzx   eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    sub     eax, edx
    jnz     .sc_done
    test    dl, dl
    jz      .sc_done
    inc     r8d
    jmp     .sc_loop
.sc_done:
    ret

str_prefix_match:
    xor     r8d, r8d
.sp_loop:
    cmp     r8d, edx
    jge     .sp_match
    movzx   eax, byte [rdi + r8]
    cmp     al, byte [rsi + r8]
    jne     .sp_nomatch
    inc     r8d
    jmp     .sp_loop
.sp_match:
    mov     eax, 1
    ret
.sp_nomatch:
    xor     eax, eax
    ret

; ============================================================
; Data
; ============================================================
str_help:
    db "Usage: expr EXPRESSION", 10
    db "  or:  expr OPTION", 10, 10
    db "      --help     display this help and exit", 10
    db "      --version  output version information and exit", 10, 10
    db "Print the value of EXPRESSION to standard output.  A blank line below", 10
    db "separates increasing precedence groups.  EXPRESSION may be:", 10, 10
    db "  ARG1 | ARG2       ARG1 if it is neither null nor 0, otherwise ARG2", 10
    db "  ARG1 & ARG2       ARG1 if neither argument is null or 0, otherwise 0", 10, 10
    db "  ARG1 < ARG2       ARG1 is less than ARG2", 10
    db "  ARG1 <= ARG2      ARG1 is less than or equal to ARG2", 10
    db "  ARG1 = ARG2       ARG1 is equal to ARG2", 10
    db "  ARG1 != ARG2      ARG1 is not equal to ARG2", 10
    db "  ARG1 >= ARG2      ARG1 is greater than or equal to ARG2", 10
    db "  ARG1 > ARG2       ARG1 is greater than ARG2", 10, 10
    db "  ARG1 + ARG2       arithmetic sum of ARG1 and ARG2", 10
    db "  ARG1 - ARG2       arithmetic difference of ARG1 and ARG2", 10, 10
    db "  ARG1 * ARG2       arithmetic product of ARG1 and ARG2", 10
    db "  ARG1 / ARG2       arithmetic quotient of ARG1 divided by ARG2", 10
    db "  ARG1 % ARG2       arithmetic remainder of ARG1 divided by ARG2", 10, 10
    db "  STRING : REGEXP   anchored pattern match of REGEXP in STRING", 10
    db "  match STRING REGEXP   same as STRING : REGEXP", 10
    db "  substr STRING POS LENGTH   substring of STRING, POS counted from 1", 10
    db "  index STRING CHARS   index in STRING where any CHARS is found, or 0", 10
    db "  length STRING     length of STRING", 10
    db "  + TOKEN           interpret TOKEN as a string", 10
    db "  ( EXPRESSION )    value of EXPRESSION", 10, 10
    db "Exit status is 0 if EXPRESSION is neither null nor 0, 1 if EXPRESSION is", 10
    db "null or 0, 2 if EXPRESSION is syntactically invalid, and 3 if an error", 10
    db "occurred.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/expr>", 10
    db "or available locally via: info '(coreutils) expr invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "expr (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Mike Parker.", 10
str_version_len equ $ - str_version

str_prefix:      db "expr: "
str_prefix_len   equ $ - str_prefix
str_missing:     db "missing operand", 10
str_missing_len  equ $ - str_missing
str_syntax:      db "syntax error", 10
str_syntax_len   equ $ - str_syntax
str_divzero:     db "division by zero", 10
str_divzero_len  equ $ - str_divzero
str_sq_nl:       db "'", 10
str_try:         db "Try 'expr --help' for more information.", 10
str_try_len      equ $ - str_try
str_newline:     db 10
str_minus:       db "-"
str_empty:       db 0

str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_length_kw:   db "length", 0
str_substr_kw:   db "substr", 0
str_index_kw:    db "index", 0

file_size equ $ - $$
