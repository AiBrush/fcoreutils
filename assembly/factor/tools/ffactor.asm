; ============================================================================
;  ffactor.asm — GNU-compatible "factor" in x86-64 Linux assembly
;
;  Algorithm:
;    1. Trial division by 2, 3, 5 (bit tricks + div)
;    2. Wheel factorization (2,3,5 wheel) up to 1009
;    3. For remainders > 1: Miller-Rabin primality test
;    4. If composite: Pollard's rho with Brent's improvement
;    5. Recursive factorization of found factors
;
;  BUILD: cd assembly/factor && make dev
; ============================================================================

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_write_err
extern asm_exit
extern asm_strlen
extern asm_read

%define OUTBUF_SIZE     131072
%define INBUF_SIZE      65536
%define MAX_FACTORS     64

section .data

err_prefix:     db "factor: "
err_prefix_len  equ $ - err_prefix
err_lquote:     db 0xE2, 0x80, 0x98
err_lquote_len  equ $ - err_lquote
err_rquote:     db 0xE2, 0x80, 0x99
err_rquote_len  equ $ - err_rquote
err_suffix:     db " is not a valid positive integer", 10
err_suffix_len  equ $ - err_suffix

help_text:
    db "Usage: factor [OPTION] [NUMBER]...", 10
    db "Print the prime factors of each specified integer NUMBER.  If none", 10
    db "are specified on the command line, read them from standard input.", 10
    db 10
    db "      --help     display this help and exit", 10
    db "      --version  output version information and exit", 10
help_text_len   equ $ - help_text

version_text:
    db "factor (fcoreutils) 0.19.4", 10
version_text_len equ $ - version_text

str_help:       db "--help", 0
str_version:    db "--version", 0

wheel235:       db 4,2,4,2,4,6,2,6

; 2-digit lookup table for fast integer-to-string conversion
; Each entry is 2 bytes: tens digit, ones digit (ASCII)
digit_pairs:
    db "00010203040506070809"
    db "10111213141516171819"
    db "20212223242526272829"
    db "30313233343536373839"
    db "40414243444546474849"
    db "50515253545556575859"
    db "60616263646566676869"
    db "70717273747576777879"
    db "80818283848586878889"
    db "90919293949596979899"

; Miller-Rabin witnesses for 64-bit: {2,3,5,7,11,13,17,19,23,29,31,37}
mr_witnesses:   dq 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37
mr_witness_count equ 12

section .bss
outbuf:         resb OUTBUF_SIZE
outbuf_pos:     resq 1
inbuf:          resb INBUF_SIZE
factors:        resq MAX_FACTORS
factor_count:   resq 1
had_error:      resb 1
argc:           resq 1
argv:           resq 1

section .text
global _start

; ============================================================================
;                           ENTRY POINT
; ============================================================================
_start:
    sub     rsp, 16
    mov     qword [rsp], 0x1000
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    mov     rax, [rsp]
    mov     [rel argc], rax
    lea     rax, [rsp + 8]
    mov     [rel argv], rax

    mov     qword [rel outbuf_pos], 0
    mov     byte [rel had_error], 0

    mov     rax, [rel argc]
    cmp     rax, 1
    je      .stdin_mode

    mov     rcx, 1
    mov     r14, [rel argc]
    mov     r15, [rel argv]
    xor     r13d, r13d
    xor     ebp, ebp

.arg_loop:
    cmp     rcx, r14
    jge     .args_done
    mov     rdi, [r15 + rcx*8]
    push    rcx
    push    r14
    push    r15
    push    r13
    push    rbp

    test    r13d, r13d
    jnz     .process_as_number

    cmp     byte [rdi], '-'
    jne     .process_as_number
    cmp     byte [rdi+1], '-'
    jne     .process_as_number

    push    rdi
    lea     rsi, [rel str_help]
    call    str_eq
    pop     rdi
    test    eax, eax
    jnz     .do_help

    push    rdi
    lea     rsi, [rel str_version]
    call    str_eq
    pop     rdi
    test    eax, eax
    jnz     .do_version

    cmp     byte [rdi+2], 0
    jne     .process_as_number

    pop     rbp
    pop     r13
    mov     r13d, 1
    pop     r15
    pop     r14
    pop     rcx
    inc     rcx
    jmp     .arg_loop

.process_as_number:
    call    process_arg_number
    pop     rbp
    mov     ebp, 1
    pop     r13
    pop     r15
    pop     r14
    pop     rcx
    inc     rcx
    jmp     .arg_loop

.do_help:
    call    flush_outbuf
    mov     rdi, STDOUT
    lea     rsi, [rel help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    call    asm_exit

.do_version:
    call    flush_outbuf
    mov     rdi, STDOUT
    lea     rsi, [rel version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    call    asm_exit

.args_done:
    test    ebp, ebp
    jz      .stdin_mode
    call    flush_outbuf
    test    rax, rax
    js      .epipe_exit
    movzx   edi, byte [rel had_error]
    call    asm_exit

.stdin_mode:
    call    process_stdin
    call    flush_outbuf
    test    rax, rax
    js      .epipe_exit
    movzx   edi, byte [rel had_error]
    call    asm_exit

.epipe_exit:
    xor     edi, edi
    call    asm_exit

; ============================================================================
str_eq:
    xor     eax, eax
.loop:
    mov     cl, [rdi]
    mov     dl, [rsi]
    cmp     cl, dl
    jne     .ne
    test    cl, cl
    jz      .eq
    inc     rdi
    inc     rsi
    jmp     .loop
.eq:
    mov     eax, 1
.ne:
    ret

; ============================================================================
process_arg_number:
    push    rbx
    push    r12
    mov     r12, rdi
    call    asm_strlen
    mov     rbx, rax
    mov     rdi, r12
    mov     rsi, rbx
    call    parse_and_factor
    pop     r12
    pop     rbx
    ret

; ============================================================================
; parse_and_factor(rdi=str, rsi=len)
; ============================================================================
parse_and_factor:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12, rdi
    mov     r13, rsi

    test    r13, r13
    jz      .pf_invalid

    mov     r14, r12
    mov     r15, r13
    cmp     byte [r14], '+'
    jne     .pf_no_plus
    inc     r14
    dec     r15
    test    r15, r15
    jz      .pf_invalid
.pf_no_plus:

    xor     rbx, rbx
    xor     ecx, ecx
    xor     ebp, ebp

.pf_parse_loop:
    cmp     rcx, r15
    jge     .pf_parse_done
    movzx   eax, byte [r14 + rcx]
    sub     eax, '0'
    cmp     eax, 9
    ja      .pf_invalid

    test    ebp, ebp
    jnz     .pf_skip_overflow

    mov     rdx, 0x1999999999999999
    cmp     rbx, rdx
    ja      .pf_set_overflow
    jb      .pf_no_overflow
    cmp     eax, 5
    ja      .pf_set_overflow

.pf_no_overflow:
    imul    rbx, rbx, 10
    add     rbx, rax
    inc     rcx
    jmp     .pf_parse_loop

.pf_set_overflow:
    mov     ebp, 1
.pf_skip_overflow:
    inc     rcx
    jmp     .pf_parse_loop

.pf_parse_done:
    test    ebp, ebp
    jnz     .pf_invalid

    ; rbx = number. Factorize.
    mov     qword [rel factor_count], 0
    mov     rdi, rbx
    call    factorize_full

    ; Sort factors in ascending order
    call    sort_factors

    ; Write "N:" to outbuf
    mov     rdi, rbx
    call    write_u64_to_outbuf
    mov     al, ':'
    call    write_char_to_outbuf

    ; Write factors
    mov     rcx, [rel factor_count]
    test    rcx, rcx
    jz      .pf_no_factors

    lea     r15, [rel factors]
    xor     r14d, r14d
.pf_write_factors:
    cmp     r14, [rel factor_count]
    jge     .pf_no_factors
    mov     al, ' '
    call    write_char_to_outbuf
    mov     rdi, [r15 + r14*8]
    call    write_u64_to_outbuf
    inc     r14
    jmp     .pf_write_factors

.pf_no_factors:
    mov     al, 10
    call    write_char_to_outbuf
    call    maybe_flush
    jmp     .pf_done

.pf_invalid:
    mov     byte [rel had_error], 1
    call    flush_outbuf
    lea     rsi, [rel err_prefix]
    mov     rdx, err_prefix_len
    call    asm_write_err
    lea     rsi, [rel err_lquote]
    mov     rdx, err_lquote_len
    call    asm_write_err
    mov     rsi, r12
    mov     rdx, r13
    call    asm_write_err
    lea     rsi, [rel err_rquote]
    mov     rdx, err_rquote_len
    call    asm_write_err
    lea     rsi, [rel err_suffix]
    mov     rdx, err_suffix_len
    call    asm_write_err

.pf_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; factorize_full(rdi=number)
; Complete factorization: trial division + Miller-Rabin + Pollard's rho.
; Appends to factors[] array at factor_count.
; ============================================================================
factorize_full:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     rbx, rdi
    lea     r15, [rel factors]

    cmp     rbx, 1
    jbe     .ff_done

    ; ── Divide out 2s ──
.ff_div2:
    test    rbx, 1
    jnz     .ff_div2_done
    mov     r12, [rel factor_count]
    mov     qword [r15 + r12*8], 2
    inc     r12
    mov     [rel factor_count], r12
    shr     rbx, 1
    jmp     .ff_div2
.ff_div2_done:
    cmp     rbx, 1
    je      .ff_done

    ; ── Check if n fits in 32 bits for fast path ──
    mov     rax, rbx
    shr     rax, 32
    test    eax, eax
    jnz     .ff_div3_64

    ; ════════════════════════════════════════════════════════
    ; 32-bit fast path: all trial division uses 32-bit div
    ; ════════════════════════════════════════════════════════
    mov     ebx, ebx                    ; zero-extend to clear upper 32 bits

    ; ── Divide out 3 (32-bit) ──
.ff_div3_32:
    mov     eax, ebx
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    test    edx, edx
    jnz     .ff_div3_32_done
    mov     r12, [rel factor_count]
    mov     qword [r15 + r12*8], 3
    inc     r12
    mov     [rel factor_count], r12
    mov     ebx, eax
    cmp     ebx, 1
    jne     .ff_div3_32
.ff_div3_32_done:
    cmp     ebx, 1
    je      .ff_done

    ; ── Divide out 5 (32-bit) ──
.ff_div5_32:
    mov     eax, ebx
    xor     edx, edx
    mov     ecx, 5
    div     ecx
    test    edx, edx
    jnz     .ff_div5_32_done
    mov     r12, [rel factor_count]
    mov     qword [r15 + r12*8], 5
    inc     r12
    mov     [rel factor_count], r12
    mov     ebx, eax
    cmp     ebx, 1
    jne     .ff_div5_32
.ff_div5_32_done:
    cmp     ebx, 1
    je      .ff_done

    ; ── Wheel trial division 7..1009 (32-bit) ──
    mov     r13d, 7
    xor     r14d, r14d

.ff_wheel_loop_32:
    cmp     r13d, 1009
    ja      .ff_post_trial

    mov     eax, r13d
    mul     r13d                        ; eax = r13d^2 (32-bit, fits)
    cmp     eax, ebx
    ja      .ff_post_trial

.ff_trial_32:
    mov     eax, ebx
    xor     edx, edx
    div     r13d
    test    edx, edx
    jnz     .ff_wheel_advance_32

    mov     r12, [rel factor_count]
    mov     [r15 + r12*8], r13
    inc     r12
    mov     [rel factor_count], r12
    mov     ebx, eax
    cmp     ebx, 1
    je      .ff_done
    jmp     .ff_wheel_loop_32

.ff_wheel_advance_32:
    lea     rax, [rel wheel235]
    movzx   ecx, byte [rax + r14]
    add     r13d, ecx
    inc     r14d
    and     r14d, 7
    jmp     .ff_wheel_loop_32

    ; ════════════════════════════════════════════════════════
    ; 64-bit path: for numbers > 2^32
    ; ════════════════════════════════════════════════════════

    ; ── Divide out 3 (64-bit) ──
.ff_div3_64:
    mov     rax, rbx
    xor     edx, edx
    mov     rcx, 3
    div     rcx
    test    rdx, rdx
    jnz     .ff_div3_64_done
    mov     r12, [rel factor_count]
    mov     qword [r15 + r12*8], 3
    inc     r12
    mov     [rel factor_count], r12
    mov     rbx, rax
    cmp     rbx, 1
    jne     .ff_div3_64
.ff_div3_64_done:
    cmp     rbx, 1
    je      .ff_done

    ; ── Divide out 5 (64-bit) ──
.ff_div5_64:
    mov     rax, rbx
    xor     edx, edx
    mov     rcx, 5
    div     rcx
    test    rdx, rdx
    jnz     .ff_div5_64_done
    mov     r12, [rel factor_count]
    mov     qword [r15 + r12*8], 5
    inc     r12
    mov     [rel factor_count], r12
    mov     rbx, rax
    cmp     rbx, 1
    jne     .ff_div5_64
.ff_div5_64_done:
    cmp     rbx, 1
    je      .ff_done

    ; ── Wheel trial division from 7 up to 1009 (64-bit) ──
    mov     r13, 7
    xor     r14d, r14d

.ff_wheel_loop:
    cmp     r13, 1009
    ja      .ff_post_trial

    ; Check r13*r13 > rbx
    mov     rax, r13
    mul     r13
    test    rdx, rdx
    jnz     .ff_post_trial
    cmp     rax, rbx
    ja      .ff_post_trial

.ff_trial:
    mov     rax, rbx
    xor     edx, edx
    div     r13
    test    rdx, rdx
    jnz     .ff_wheel_advance

    ; Found factor
    mov     r12, [rel factor_count]
    mov     [r15 + r12*8], r13
    inc     r12
    mov     [rel factor_count], r12
    mov     rbx, rax
    cmp     rbx, 1
    je      .ff_done
    ; If quotient now fits in 32 bits, switch to fast path
    mov     rax, rbx
    shr     rax, 32
    test    eax, eax
    jz      .ff_switch_to_32
    jmp     .ff_wheel_loop

.ff_switch_to_32:
    ; Continue from current wheel position in 32-bit mode
    mov     r13d, r13d
    jmp     .ff_wheel_loop_32

.ff_wheel_advance:
    lea     rax, [rel wheel235]
    movzx   ecx, byte [rax + r14]
    add     r13, rcx
    inc     r14d
    and     r14d, 7
    jmp     .ff_wheel_loop

.ff_post_trial:
    ; rbx > 1 after trial division by primes up to 1009
    cmp     rbx, 1
    je      .ff_done

    ; If rbx < 1018081 (1009^2), it must be prime
    cmp     rbx, 1018081
    jb      .ff_add_remainder

    ; Use factor_recursive for remainder
    mov     rdi, rbx
    call    factor_recursive
    jmp     .ff_done

.ff_add_remainder:
    mov     r12, [rel factor_count]
    mov     [r15 + r12*8], rbx
    inc     r12
    mov     [rel factor_count], r12

.ff_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; factor_recursive(rdi=n)
; Recursively factor n using Miller-Rabin + Pollard's rho.
; Appends prime factors to factors[] array.
; ============================================================================
factor_recursive:
    push    rbx
    push    r12

    mov     rbx, rdi

    cmp     rbx, 1
    jbe     .fr_done

    ; Check primality
    mov     rdi, rbx
    call    is_prime_mr
    test    eax, eax
    jnz     .fr_is_prime

    ; Composite — find a factor with Pollard's rho
    mov     rdi, rbx
    call    pollard_rho                 ; rax = factor d
    mov     r12, rax

    ; If rho failed (returned n), do brute-force trial division
    cmp     r12, rbx
    je      .fr_brute

    ; Recursively factor d and n/d
    mov     rdi, r12
    call    factor_recursive

    mov     rax, rbx
    xor     edx, edx
    div     r12
    mov     rdi, rax
    call    factor_recursive
    jmp     .fr_done

.fr_brute:
    ; Brute force: trial divide from 2
    mov     r12, 2
.fr_brute_loop:
    mov     rax, r12
    mul     r12
    test    rdx, rdx
    jnz     .fr_brute_remainder
    cmp     rax, rbx
    ja      .fr_brute_remainder

    mov     rax, rbx
    xor     edx, edx
    div     r12
    test    rdx, rdx
    jnz     .fr_brute_next

    ; Found factor r12, recurse
    push    rbx
    push    r12
    mov     rdi, r12
    call    factor_recursive
    pop     r12
    pop     rbx

    mov     rax, rbx
    xor     edx, edx
    div     r12
    mov     rdi, rax
    call    factor_recursive
    jmp     .fr_done

.fr_brute_next:
    inc     r12
    jmp     .fr_brute_loop

.fr_brute_remainder:
    ; rbx is prime
.fr_is_prime:
    ; Add rbx as prime factor
    lea     rax, [rel factors]
    mov     rcx, [rel factor_count]
    mov     [rax + rcx*8], rbx
    inc     rcx
    mov     [rel factor_count], rcx

.fr_done:
    pop     r12
    pop     rbx
    ret

; ============================================================================
; is_prime_mr(rdi=n) -> eax=1 if prime, 0 if composite
; Deterministic Miller-Rabin for 64-bit n.
; ============================================================================
is_prime_mr:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     rbx, rdi

    cmp     rbx, 2
    jb      .mr_composite
    je      .mr_prime
    test    rbx, 1
    jz      .mr_composite
    cmp     rbx, 3
    je      .mr_prime

    ; n-1 = d * 2^r
    mov     rax, rbx
    dec     rax
    mov     r12, rax                    ; r12 = n - 1
    xor     r13d, r13d                  ; r = 0
    mov     r14, rax                    ; d = n - 1
.mr_factor_2:
    test    r14, 1
    jnz     .mr_factor_done
    shr     r14, 1
    inc     r13d
    jmp     .mr_factor_2
.mr_factor_done:

    lea     rbp, [rel mr_witnesses]
    xor     r15d, r15d

.mr_witness_loop:
    cmp     r15d, mr_witness_count
    jge     .mr_prime

    mov     rax, [rbp + r15*8]
    cmp     rax, rbx
    jae     .mr_next_witness

    ; x = pow(a, d, n)
    mov     rdi, rax
    mov     rsi, r14
    mov     rdx, rbx
    call    mod_pow

    cmp     rax, 1
    je      .mr_next_witness
    cmp     rax, r12
    je      .mr_next_witness

    ; Square up to r-1 times
    mov     ecx, r13d
    dec     ecx
    test    ecx, ecx
    jz      .mr_composite

    mov     r8, rax                     ; x
.mr_square_loop:
    ; x = x * x mod n
    mov     rax, r8
    mul     r8                          ; rdx:rax = x^2
    div     rbx                         ; rdx = x^2 mod n
    mov     r8, rdx

    cmp     r8, r12
    je      .mr_next_witness

    dec     ecx
    test    ecx, ecx
    jnz     .mr_square_loop
    jmp     .mr_composite

.mr_next_witness:
    inc     r15d
    jmp     .mr_witness_loop

.mr_prime:
    mov     eax, 1
    jmp     .mr_ret
.mr_composite:
    xor     eax, eax
.mr_ret:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; mod_pow(rdi=base, rsi=exp, rdx=m) -> rax = base^exp mod m
; ============================================================================
mod_pow:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, rdx                    ; m
    mov     r13, rsi                    ; exp
    ; base = base % m
    mov     rax, rdi
    xor     edx, edx
    div     r12
    mov     r14, rdx                    ; base % m
    mov     rbx, 1                      ; result = 1

    cmp     r12, 1
    jbe     .mp_done_zero

.mp_loop:
    test    r13, r13
    jz      .mp_done

    test    r13, 1
    jz      .mp_no_mul

    ; result = result * base % m
    mov     rax, rbx
    mul     r14                         ; rdx:rax
    div     r12
    mov     rbx, rdx

.mp_no_mul:
    ; base = base * base % m
    mov     rax, r14
    mul     r14
    div     r12
    mov     r14, rdx

    shr     r13, 1
    jmp     .mp_loop

.mp_done_zero:
    xor     ebx, ebx
.mp_done:
    mov     rax, rbx
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; pollard_rho(rdi=n) -> rax = non-trivial factor of n (or n if failed)
; Brent's improvement of Pollard's rho with batch GCD.
;
; Register usage:
;   rbx = n
;   r12 = x (fixed point from cycle start)
;   r13 = y (running point)
;   r14 = d (gcd result)
;   r15 = c (polynomial constant)
;   rbp = saved y for backtrack
;   [rsp] = q (batch product accumulator)
; ============================================================================
pollard_rho:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8                      ; q on stack

    mov     rbx, rdi                    ; n

    ; Even check
    test    rbx, 1
    jnz     .rho_odd
    mov     rax, 2
    jmp     .rho_ret
.rho_odd:

    mov     r15, 1                      ; c = 1
.rho_c_loop:
    cmp     r15, 512
    ja      .rho_fail

    ; x = y = seed, using c * 6364136223846793005 + 1 mod n as seed
    mov     rax, r15
    mov     rcx, 6364136223846793005
    mul     rcx
    inc     rax
    xor     edx, edx
    div     rbx
    mov     r12, rdx                    ; x
    mov     r13, rdx                    ; y

    mov     rcx, 1                      ; r = 1 (range, doubles each round)

.rho_round:
    ; x = y (save cycle start)
    mov     r12, r13

    ; Advance y by r steps
    push    rcx
    mov     rdi, rcx                    ; count
.rho_advance:
    mov     rax, r13
    mul     r13
    div     rbx
    mov     r13, rdx
    add     r13, r15
    cmp     r13, rbx
    jb      .rho_adv_ok
    sub     r13, rbx
.rho_adv_ok:
    dec     rdi
    jnz     .rho_advance
    pop     rcx

    ; Batch GCD phase: process in groups of 128
    xor     r8d, r8d                    ; k = 0 (processed count)
    mov     r14, 1                      ; d = 1
    mov     qword [rsp], 1             ; q = 1

.rho_batch:
    cmp     r8, rcx
    jge     .rho_batch_end
    cmp     r14, 1
    jne     .rho_batch_end

    mov     rbp, r13                    ; ys = y (save for backtrack)

    ; Compute min(128, r - k) steps
    mov     rdi, rcx
    sub     rdi, r8
    cmp     rdi, 128
    jbe     .rho_m_ok
    mov     rdi, 128
.rho_m_ok:
    ; rdi = m (batch size)
    xor     r9d, r9d                    ; i = 0

.rho_inner:
    cmp     r9, rdi
    jge     .rho_inner_done

    ; y = (y*y + c) mod n
    mov     rax, r13
    mul     r13
    div     rbx
    mov     r13, rdx
    add     r13, r15
    cmp     r13, rbx
    jb      .rho_inner_nmod
    sub     r13, rbx
.rho_inner_nmod:

    ; q = q * |x - y| mod n
    mov     rax, r12
    sub     rax, r13
    jns     .rho_inner_abs
    neg     rax
.rho_inner_abs:
    ; q = q * |x - y| mod n (if |x-y|==0, q becomes 0 -> gcd==n -> backtrack)
    mov     r10, [rsp]                  ; load q
    mul     r10                         ; rdx:rax = q * |x-y|
    div     rbx                         ; rdx = result mod n
    mov     [rsp], rdx                  ; store q
    inc     r9
    jmp     .rho_inner

.rho_inner_done:
    ; d = gcd(q, n)
    push    rcx
    push    r8
    push    rdi
    mov     rdi, [rsp + 24]            ; q (at rsp+24 because 3 pushes above)
    mov     rsi, rbx
    call    gcd64
    mov     r14, rax
    pop     rdi
    pop     r8
    pop     rcx

    add     r8, rdi                     ; k += m
    jmp     .rho_batch

.rho_batch_end:
    ; Double r for next round
    shl     rcx, 1

    cmp     r14, 1
    je      .rho_round                  ; no factor found yet, try wider range

    cmp     r14, rbx
    jne     .rho_found                  ; found non-trivial factor

    ; d == n: batch GCD accumulated too much. Backtrack from ys.
    mov     r13, rbp                    ; restore y = ys
.rho_backtrack:
    mov     rax, r13
    mul     r13
    div     rbx
    mov     r13, rdx
    add     r13, r15
    cmp     r13, rbx
    jb      .rho_bt_ok
    sub     r13, rbx
.rho_bt_ok:
    ; d = gcd(|x - y|, n)
    mov     rdi, r12
    sub     rdi, r13
    jns     .rho_bt_abs
    neg     rdi
.rho_bt_abs:
    test    rdi, rdi
    jz      .rho_next_c                 ; x == y, try different c
    mov     rsi, rbx
    push    rcx
    call    gcd64
    pop     rcx
    cmp     rax, 1
    je      .rho_backtrack
    cmp     rax, rbx
    je      .rho_next_c
    mov     r14, rax
    jmp     .rho_found

.rho_next_c:
    inc     r15
    jmp     .rho_c_loop

.rho_found:
    mov     rax, r14
    jmp     .rho_ret

.rho_fail:
    mov     rax, rbx                    ; return n (failure)

.rho_ret:
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; gcd64(rdi=a, rsi=b) -> rax = gcd(a, b)
; Euclidean algorithm.
; ============================================================================
gcd64:
    mov     rax, rdi
    mov     rcx, rsi

    test    rax, rax
    jz      .g_ret_b
    test    rcx, rcx
    jz      .g_ret_a

.g_loop:
    xor     edx, edx
    div     rcx                         ; rax = a/b, rdx = a%b
    test    rdx, rdx
    jz      .g_ret_rcx
    mov     rax, rcx
    mov     rcx, rdx
    jmp     .g_loop

.g_ret_rcx:
    mov     rax, rcx
    ret
.g_ret_b:
    mov     rax, rcx
    ret
.g_ret_a:
    ret

; ============================================================================
; sort_factors()
; Insertion sort on factors[0..factor_count). Small array, O(n^2) is fine.
; ============================================================================
sort_factors:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     rcx, [rel factor_count]
    cmp     rcx, 2
    jl      .sf_done                    ; 0 or 1 elements, already sorted

    lea     r14, [rel factors]
    mov     r12, 1                      ; i = 1

.sf_outer:
    cmp     r12, rcx
    jge     .sf_done

    mov     rbx, [r14 + r12*8]         ; key = factors[i]
    mov     r13, r12
    dec     r13                         ; j = i - 1

.sf_inner:
    cmp     r13, 0
    jl      .sf_insert
    mov     rax, [r14 + r13*8]         ; factors[j]
    cmp     rax, rbx
    jbe     .sf_insert                  ; factors[j] <= key, done

    ; factors[j+1] = factors[j]
    lea     rdx, [r13 + 1]
    mov     [r14 + rdx*8], rax
    dec     r13
    jmp     .sf_inner

.sf_insert:
    lea     rdx, [r13 + 1]
    mov     [r14 + rdx*8], rbx         ; factors[j+1] = key
    inc     r12
    mov     rcx, [rel factor_count]     ; reload in case
    jmp     .sf_outer

.sf_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; write_u64_to_outbuf(rdi=number)
; ============================================================================
write_u64_to_outbuf:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 24

    mov     rax, rdi

    test    rax, rax
    jnz     .wu_not_zero
    mov     rcx, [rel outbuf_pos]
    lea     rbx, [rel outbuf]
    mov     byte [rbx + rcx], '0'
    inc     qword [rel outbuf_pos]
    jmp     .wu_ret

.wu_not_zero:
    ; Write digits to local buffer in reverse, then copy to outbuf
    lea     rbx, [rsp + 20]             ; end of local buf
    xor     r12d, r12d                  ; digit count
    lea     r13, [rel digit_pairs]

    ; Use 32-bit division for values that fit in 32 bits (much faster)
    mov     rdx, rax
    shr     rdx, 32
    test    edx, edx
    jnz     .wu_pairs_64

.wu_pairs_32:
    ; Extract 2 digits at a time using div-by-100 (32-bit)
    cmp     eax, 100
    jb      .wu_last_digit_32
    xor     edx, edx
    mov     ecx, 100
    div     ecx                         ; eax = n/100, edx = n%100
    ; Look up the 2-digit string
    movzx   ecx, word [r13 + rdx*2]
    sub     rbx, 2
    mov     [rbx], cx
    add     r12d, 2
    test    eax, eax
    jnz     .wu_pairs_32
    jmp     .wu_copy_start

.wu_last_digit_32:
    ; eax < 100: could be 1 or 2 digits
    cmp     eax, 10
    jb      .wu_single_32
    movzx   ecx, word [r13 + rax*2]
    sub     rbx, 2
    mov     [rbx], cx
    add     r12d, 2
    jmp     .wu_copy_start

.wu_single_32:
    add     al, '0'
    dec     rbx
    mov     [rbx], al
    inc     r12d
    jmp     .wu_copy_start

.wu_pairs_64:
    ; Extract 2 digits at a time using div-by-100 (64-bit)
    cmp     rax, 100
    jb      .wu_last_digit_64
    xor     edx, edx
    mov     rcx, 100
    div     rcx                         ; rax = n/100, rdx = n%100
    movzx   ecx, word [r13 + rdx*2]
    sub     rbx, 2
    mov     [rbx], cx
    add     r12d, 2
    ; Switch to 32-bit when possible
    mov     rdx, rax
    shr     rdx, 32
    test    edx, edx
    jz      .wu_pairs_32
    jmp     .wu_pairs_64

.wu_last_digit_64:
    ; rax < 100 (still 64-bit register but small)
    cmp     eax, 10
    jb      .wu_single_32
    movzx   ecx, word [r13 + rax*2]
    sub     rbx, 2
    mov     [rbx], cx
    add     r12d, 2
    jmp     .wu_copy_start

.wu_copy_start:
    ; Copy digits from [rbx..rbx+r12) to outbuf
    mov     rcx, [rel outbuf_pos]
    lea     r13, [rel outbuf]
    add     r13, rcx

    xor     ecx, ecx
.wu_copy:
    cmp     ecx, r12d
    jge     .wu_copy_done
    movzx   eax, byte [rbx + rcx]
    mov     [r13 + rcx], al
    inc     ecx
    jmp     .wu_copy
.wu_copy_done:
    mov     rax, [rel outbuf_pos]
    add     rax, r12
    mov     [rel outbuf_pos], rax

.wu_ret:
    add     rsp, 24
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
write_char_to_outbuf:
    mov     rcx, [rel outbuf_pos]
    lea     rdx, [rel outbuf]
    mov     [rdx + rcx], al
    inc     qword [rel outbuf_pos]
    ret

; ============================================================================
flush_outbuf:
    mov     rdx, [rel outbuf_pos]
    test    rdx, rdx
    jz      .fl_nothing
    mov     rdi, STDOUT
    lea     rsi, [rel outbuf]
    call    asm_write_all
    mov     qword [rel outbuf_pos], 0
    ret
.fl_nothing:
    xor     eax, eax
    ret

; ============================================================================
maybe_flush:
    mov     rax, [rel outbuf_pos]
    cmp     rax, 65536
    jb      .mf_skip
    jmp     flush_outbuf
.mf_skip:
    ret

; ============================================================================
process_stdin:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    xor     r14d, r14d

.ps_read_loop:
    mov     rdi, STDIN
    lea     rsi, [rel inbuf]
    add     rsi, r14
    mov     rdx, INBUF_SIZE
    sub     rdx, r14
    call    asm_read

    test    rax, rax
    jle     .ps_read_eof
    add     r14, rax

    lea     rdi, [rel inbuf]
    mov     rsi, r14
    call    find_last_newline
    test    rax, rax
    jz      .ps_no_newline

    mov     r15, rax
    lea     rdi, [rel inbuf]
    mov     rsi, r15
    call    process_buffer

    mov     rcx, r14
    sub     rcx, r15
    test    rcx, rcx
    jz      .ps_no_leftover

    push    rcx
    lea     rdi, [rel inbuf]
    lea     rsi, [rel inbuf]
    add     rsi, r15
    rep     movsb
    pop     r14
    jmp     .ps_read_loop

.ps_no_leftover:
    xor     r14d, r14d
    jmp     .ps_read_loop

.ps_no_newline:
    cmp     r14, INBUF_SIZE
    jl      .ps_read_loop
    lea     rdi, [rel inbuf]
    mov     rsi, r14
    call    process_buffer
    xor     r14d, r14d
    jmp     .ps_read_loop

.ps_read_eof:
    test    r14, r14
    jz      .ps_done
    lea     rdi, [rel inbuf]
    mov     rsi, r14
    call    process_buffer

.ps_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
find_last_newline:
    mov     rax, rsi
.fln_scan:
    test    rax, rax
    jz      .fln_none
    dec     rax
    cmp     byte [rdi + rax], 10
    jne     .fln_scan
    inc     rax
    ret
.fln_none:
    xor     eax, eax
    ret

; ============================================================================
process_buffer:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, rdi
    mov     r13, rsi
    xor     r14d, r14d

.pb_token_loop:
.pb_skip_ws:
    cmp     r14, r13
    jge     .pb_done
    movzx   eax, byte [r12 + r14]
    cmp     al, ' '
    je      .pb_ws_next
    cmp     al, 10
    je      .pb_ws_next
    cmp     al, 9
    je      .pb_ws_next
    cmp     al, 13
    je      .pb_ws_next
    jmp     .pb_token_start

.pb_ws_next:
    inc     r14
    jmp     .pb_skip_ws

.pb_token_start:
    mov     rbx, r14
.pb_scan_token:
    inc     r14
    cmp     r14, r13
    jge     .pb_token_end
    movzx   eax, byte [r12 + r14]
    cmp     al, ' '
    je      .pb_token_end
    cmp     al, 10
    je      .pb_token_end
    cmp     al, 9
    je      .pb_token_end
    cmp     al, 13
    je      .pb_token_end
    jmp     .pb_scan_token

.pb_token_end:
    lea     rdi, [r12 + rbx]
    mov     rsi, r14
    sub     rsi, rbx
    push    r12
    push    r13
    push    r14
    call    parse_and_factor
    pop     r14
    pop     r13
    pop     r12
    jmp     .pb_token_loop

.pb_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
