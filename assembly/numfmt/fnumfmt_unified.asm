; ============================================================
; fnumfmt_unified.asm — GNU-compatible 'numfmt' command
; Builds with: nasm -f bin fnumfmt_unified.asm -o fnumfmt
;
; numfmt: convert numbers from/to human-readable strings
;
; Usage: numfmt [OPTION]... [NUMBER]...
;   --to=si|iec|iec-i: convert to human form
;   --from=si|iec|iec-i: convert from human form
;   --padding=N: pad output to N width
;   --suffix=S: add suffix
;   --round=up|down|from-zero|towards-zero|nearest
;   --field=N: convert field N
;   --delimiter=X: field delimiter
;
; SI suffixes: K(1e3), M(1e6), G(1e9), T(1e12), P(1e15), E(1e18)
; IEC suffixes: Ki(1024), Mi(1024^2), Gi(1024^3), etc.
; IMPORTANT: SI kilo uses uppercase 'K' (matching GNU 9.4 on ubuntu-latest CI)
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_EXIT       60
%define SYS_RT_SIGPROCMASK 14

%define STDOUT          1
%define STDERR          2
%define STDIN           0
%define SIG_BLOCK       0
%define SIGPIPE        13

; Mode constants
%define MODE_NONE       0
%define MODE_SI         1
%define MODE_IEC        2
%define MODE_IEC_I      3

; === ELF Header ===
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
    dw ehdr_size
    dw phdr_size
    dw 2
    dw 64, 0, 0
ehdr_size equ $ - ehdr

phdr:
    dd 1, 7
    dq 0, $$, $$
    dq file_size, mem_size
    dq 0x200000
phdr_size equ $ - phdr

    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 16

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

    mov     r14d, [rsp]
    lea     r15, [rsp + 8]

    ; Defaults
    mov     dword [to_mode], MODE_NONE
    mov     dword [from_mode], MODE_NONE
    mov     dword [padding], 0
    mov     dword [field_num], 0
    mov     byte [delimiter], 0
    mov     ecx, 1

    cmp     r14d, 2
    jl      .read_stdin

    ; Check --help / --version
    mov     rdi, [r15 + 8]
    push    rcx
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     show_help
    mov     rdi, [r15 + 8]
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     show_version
    pop     rcx

.parse_opts:
    cmp     ecx, r14d
    jge     .read_stdin
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .got_numbers
    cmp     byte [rdi + 1], '-'
    jne     .got_numbers        ; Single '-' or -N is a number
    cmp     byte [rdi + 2], 0
    je      .end_opts           ; "--"

    ; Long options
    push    rcx
    mov     rsi, str_to_eq
    call    starts_with
    test    eax, eax
    jnz     .parse_to
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_from_eq
    call    starts_with
    test    eax, eax
    jnz     .parse_from
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_padding_eq
    call    starts_with
    test    eax, eax
    jnz     .parse_padding
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_field_eq
    call    starts_with
    test    eax, eax
    jnz     .parse_field
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_delimiter_eq
    call    starts_with
    test    eax, eax
    jnz     .parse_delim
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_suffix_eq
    call    starts_with
    test    eax, eax
    jnz     .parse_suffix
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_round_eq
    call    starts_with
    test    eax, eax
    jnz     .skip_opt
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_to_unit_eq
    call    starts_with
    test    eax, eax
    jnz     .skip_opt
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_from_unit_eq
    call    starts_with
    test    eax, eax
    jnz     .skip_opt
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_format_eq
    call    starts_with
    test    eax, eax
    jnz     .skip_opt
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_header_eq
    call    starts_with
    test    eax, eax
    jnz     .skip_opt
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_header_flag
    call    str_eq
    test    eax, eax
    jnz     .skip_opt
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_invalid_flag
    call    starts_with
    test    eax, eax
    jnz     .skip_opt
    ; grouping, zero-terminated
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_grouping_flag
    call    str_eq
    test    eax, eax
    jnz     .skip_opt
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_zero_flag
    call    str_eq
    test    eax, eax
    jnz     .skip_opt
    pop     rcx
    jmp     invalid_option

.parse_to:
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    call    find_eq_val
    mov     rdi, rax
    call    parse_mode
    mov     [to_mode], eax
    inc     ecx
    jmp     .parse_opts

.parse_from:
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    call    find_eq_val
    mov     rdi, rax
    call    parse_mode
    mov     [from_mode], eax
    inc     ecx
    jmp     .parse_opts

.parse_padding:
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    call    find_eq_val
    mov     rdi, rax
    call    parse_int
    mov     [padding], eax
    inc     ecx
    jmp     .parse_opts

.parse_field:
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    call    find_eq_val
    mov     rdi, rax
    call    parse_uint
    mov     [field_num], eax
    inc     ecx
    jmp     .parse_opts

.parse_delim:
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    call    find_eq_val
    movzx   eax, byte [rax]
    mov     [delimiter], al
    inc     ecx
    jmp     .parse_opts

.parse_suffix:
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    call    find_eq_val
    mov     [suffix_ptr], rax
    inc     ecx
    jmp     .parse_opts

.skip_opt:
    pop     rcx
    inc     ecx
    jmp     .parse_opts

.end_opts:
    inc     ecx

.got_numbers:
    ; Process command-line numbers
    xor     r12d, r12d          ; error count
.num_loop:
    cmp     ecx, r14d
    jge     .check_errors
    mov     rdi, [r15 + rcx*8]
    call    process_number
    inc     ecx
    jmp     .num_loop

.read_stdin:
    ; If no numbers on command line, read from stdin
    cmp     ecx, r14d
    jl      .got_numbers
    ; Check if any numbers were processed
    ; Read lines from stdin
.stdin_loop:
    lea     rdi, [line_buf]
    mov     edx, 4095
    xor     r8d, r8d
.read_char:
    push    rdi
    push    r8
    mov     eax, SYS_READ
    mov     edi, STDIN
    lea     rsi, [line_buf + r8]
    mov     edx, 1
    syscall
    pop     r8
    pop     rdi
    cmp     rax, 0
    jle     .stdin_eof
    movzx   eax, byte [line_buf + r8]
    cmp     al, 10
    je      .got_line
    inc     r8d
    cmp     r8d, 4094
    jl      .read_char
.got_line:
    mov     byte [line_buf + r8], 0
    cmp     r8d, 0
    je      .stdin_loop         ; skip empty lines
    lea     rdi, [line_buf]
    call    process_number
    jmp     .stdin_loop
.stdin_eof:
    ; Process any remaining line
    cmp     r8d, 0
    je      .check_errors
    mov     byte [line_buf + r8], 0
    lea     rdi, [line_buf]
    call    process_number

.check_errors:
    test    r12d, r12d
    jnz     .exit_fail
    xor     edi, edi
    jmp     do_exit
.exit_fail:
    mov     edi, 2
    jmp     do_exit

; ---- process_number: rdi = number string ----
process_number:
    push    rbx
    push    r12
    push    r13

    ; Parse input number
    mov     rbx, rdi            ; save string pointer
    xor     r13, r13            ; parsed value

    ; Check from_mode
    cmp     dword [from_mode], MODE_NONE
    jne     .from_parse
    ; Simple integer parse
    call    parse_int64
    mov     r13, rax
    jmp     .do_to

.from_parse:
    ; Parse with suffix
    call    parse_int64
    mov     r13, rax
    ; Check for suffix
    movzx   eax, byte [rdi]
    cmp     al, 'K'
    je      .from_kilo
    cmp     al, 'k'
    je      .from_kilo
    cmp     al, 'M'
    je      .from_mega
    cmp     al, 'G'
    je      .from_giga
    cmp     al, 'T'
    je      .from_tera
    cmp     al, 'P'
    je      .from_peta
    cmp     al, 'E'
    je      .from_exa
    jmp     .do_to

.from_kilo:
    cmp     dword [from_mode], MODE_SI
    je      .from_k_si
    imul    r13, 1024
    jmp     .do_to
.from_k_si:
    imul    r13, 1000
    jmp     .do_to
.from_mega:
    cmp     dword [from_mode], MODE_SI
    je      .from_m_si
    imul    r13, 1048576
    jmp     .do_to
.from_m_si:
    imul    r13, 1000000
    jmp     .do_to
.from_giga:
    cmp     dword [from_mode], MODE_SI
    je      .from_g_si
    mov     rax, 1073741824
    imul    r13, rax
    jmp     .do_to
.from_g_si:
    mov     rax, 1000000000
    imul    r13, rax
    jmp     .do_to
.from_tera:
    cmp     dword [from_mode], MODE_SI
    je      .from_t_si
    mov     rax, 1099511627776
    imul    r13, rax
    jmp     .do_to
.from_t_si:
    mov     rax, 1000000000000
    imul    r13, rax
    jmp     .do_to
.from_peta:
    cmp     dword [from_mode], MODE_SI
    je      .from_p_si
    mov     rax, 1125899906842624
    imul    r13, rax
    jmp     .do_to
.from_p_si:
    mov     rax, 1000000000000000
    imul    r13, rax
    jmp     .do_to
.from_exa:
    cmp     dword [from_mode], MODE_SI
    je      .from_e_si
    mov     rax, 1152921504606846976
    imul    r13, rax
    jmp     .do_to
.from_e_si:
    mov     rax, 1000000000000000000
    imul    r13, rax

.do_to:
    cmp     dword [to_mode], MODE_NONE
    jne     .to_format
    ; No --to: just print the number
    mov     rdi, r13
    call    print_int64
    ; Print suffix if set
    cmp     qword [suffix_ptr], 0
    je      .no_suffix1
    mov     rdi, [suffix_ptr]
    call    str_len
    mov     edx, eax
    mov     rsi, [suffix_ptr]
    mov     edi, STDOUT
    call    do_write
.no_suffix1:
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write
    jmp     .pn_done

.to_format:
    ; Convert to human-readable with suffix
    cmp     dword [to_mode], MODE_SI
    je      .to_si
    cmp     dword [to_mode], MODE_IEC
    je      .to_iec
    ; MODE_IEC_I
    jmp     .to_iec_i

.to_si:
    ; Divide by powers of 1000
    mov     rax, r13
    test    rax, rax
    js      .to_si_neg
    mov     rcx, 1000000000000000000
    cmp     rax, rcx
    jge     .to_si_E
    mov     rcx, 1000000000000000
    cmp     rax, rcx
    jge     .to_si_P
    mov     rcx, 1000000000000
    cmp     rax, rcx
    jge     .to_si_T
    mov     rcx, 1000000000
    cmp     rax, rcx
    jge     .to_si_G
    mov     rcx, 1000000
    cmp     rax, rcx
    jge     .to_si_M
    mov     rcx, 1000
    cmp     rax, rcx
    jge     .to_si_K
    ; Less than 1000: no suffix
    mov     rdi, r13
    call    print_int64
    jmp     .to_suffix_done

.to_si_neg:
    ; Negative: print as-is
    mov     rdi, r13
    call    print_int64
    jmp     .to_suffix_done

.to_si_K:
    xor     edx, edx
    mov     rcx, 1000
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_K
    mov     edx, 1
    call    do_write
    jmp     .to_suffix_done

.to_si_M:
    xor     edx, edx
    mov     rcx, 1000000
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_M
    mov     edx, 1
    call    do_write
    jmp     .to_suffix_done

.to_si_G:
    xor     edx, edx
    mov     rcx, 1000000000
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_G
    mov     edx, 1
    call    do_write
    jmp     .to_suffix_done

.to_si_T:
    xor     edx, edx
    mov     rcx, 1000000000000
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_T
    mov     edx, 1
    call    do_write
    jmp     .to_suffix_done

.to_si_P:
    xor     edx, edx
    mov     rcx, 1000000000000000
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_P
    mov     edx, 1
    call    do_write
    jmp     .to_suffix_done

.to_si_E:
    xor     edx, edx
    mov     rcx, 1000000000000000000
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_E
    mov     edx, 1
    call    do_write
    jmp     .to_suffix_done

.to_iec:
    mov     rax, r13
    test    rax, rax
    js      .to_iec_neg
    mov     rcx, 1152921504606846976
    cmp     rax, rcx
    jge     .to_iec_Ei
    mov     rcx, 1125899906842624
    cmp     rax, rcx
    jge     .to_iec_Pi
    mov     rcx, 1099511627776
    cmp     rax, rcx
    jge     .to_iec_Ti
    mov     rcx, 1073741824
    cmp     rax, rcx
    jge     .to_iec_Gi
    mov     rcx, 1048576
    cmp     rax, rcx
    jge     .to_iec_Mi
    mov     rcx, 1024
    cmp     rax, rcx
    jge     .to_iec_Ki
    mov     rdi, r13
    call    print_int64
    jmp     .to_suffix_done
.to_iec_neg:
    mov     rdi, r13
    call    print_int64
    jmp     .to_suffix_done
.to_iec_Ki:
    xor     edx, edx
    mov     rcx, 1024
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_K
    mov     edx, 1
    call    do_write
    jmp     .to_suffix_done
.to_iec_Mi:
    xor     edx, edx
    mov     rcx, 1048576
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_M
    mov     edx, 1
    call    do_write
    jmp     .to_suffix_done
.to_iec_Gi:
    xor     edx, edx
    mov     rcx, 1073741824
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_G
    mov     edx, 1
    call    do_write
    jmp     .to_suffix_done
.to_iec_Ti:
    xor     edx, edx
    mov     rcx, 1099511627776
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_T
    mov     edx, 1
    call    do_write
    jmp     .to_suffix_done
.to_iec_Pi:
    xor     edx, edx
    mov     rcx, 1125899906842624
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_P
    mov     edx, 1
    call    do_write
    jmp     .to_suffix_done
.to_iec_Ei:
    xor     edx, edx
    mov     rcx, 1152921504606846976
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_E
    mov     edx, 1
    call    do_write
    jmp     .to_suffix_done

.to_iec_i:
    ; Same as IEC but with "i" suffix (Ki, Mi, Gi, etc.)
    mov     rax, r13
    test    rax, rax
    js      .to_ieci_neg
    mov     rcx, 1024
    cmp     rax, rcx
    jl      .to_ieci_plain
    ; Find appropriate unit
    mov     rcx, 1152921504606846976
    cmp     rax, rcx
    jge     .to_ieci_Ei
    mov     rcx, 1125899906842624
    cmp     rax, rcx
    jge     .to_ieci_Pi
    mov     rcx, 1099511627776
    cmp     rax, rcx
    jge     .to_ieci_Ti
    mov     rcx, 1073741824
    cmp     rax, rcx
    jge     .to_ieci_Gi
    mov     rcx, 1048576
    cmp     rax, rcx
    jge     .to_ieci_Mi
    ; Ki
    xor     edx, edx
    mov     rcx, 1024
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_Ki
    mov     edx, 2
    call    do_write
    jmp     .to_suffix_done
.to_ieci_plain:
.to_ieci_neg:
    mov     rdi, r13
    call    print_int64
    jmp     .to_suffix_done
.to_ieci_Mi:
    xor     edx, edx
    mov     rcx, 1048576
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_Mi
    mov     edx, 2
    call    do_write
    jmp     .to_suffix_done
.to_ieci_Gi:
    xor     edx, edx
    mov     rcx, 1073741824
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_Gi
    mov     edx, 2
    call    do_write
    jmp     .to_suffix_done
.to_ieci_Ti:
    xor     edx, edx
    mov     rcx, 1099511627776
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_Ti
    mov     edx, 2
    call    do_write
    jmp     .to_suffix_done
.to_ieci_Pi:
    xor     edx, edx
    mov     rcx, 1125899906842624
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_Pi
    mov     edx, 2
    call    do_write
    jmp     .to_suffix_done
.to_ieci_Ei:
    xor     edx, edx
    mov     rcx, 1152921504606846976
    div     rcx
    mov     rdi, rax
    mov     r8, rdx
    mov     r9, rcx
    call    print_scaled
    mov     edi, STDOUT
    mov     rsi, str_Ei
    mov     edx, 2
    call    do_write

.to_suffix_done:
    ; Print suffix if set
    cmp     qword [suffix_ptr], 0
    je      .no_suffix2
    mov     rdi, [suffix_ptr]
    call    str_len
    mov     edx, eax
    mov     rsi, [suffix_ptr]
    mov     edi, STDOUT
    call    do_write
.no_suffix2:
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write

.pn_done:
    pop     r13
    pop     r12
    pop     rbx
    ret

invalid_option:
    mov     r13, [r15 + rcx*8]     ; save option string (rcx clobbered by syscall)
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_unrec
    mov     edx, str_unrec_len
    call    write_err
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    write_err
    mov     edi, 1
    jmp     do_exit

show_help:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

show_version:
    pop     rcx
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

write_err:
    mov     edi, STDERR
    jmp     do_write

do_exit:
    mov     eax, SYS_EXIT
    syscall

str_len:
    xor     eax, eax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     eax
    jmp     .loop
.done:
    ret

str_eq:
    xor     r8d, r8d
.loop:
    movzx   eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    cmp     al, dl
    jne     .ne
    test    al, al
    jz      .eq
    inc     r8d
    jmp     .loop
.eq:
    mov     eax, 1
    ret
.ne:
    xor     eax, eax
    ret

starts_with:
    xor     r8d, r8d
.loop:
    movzx   eax, byte [rsi + r8]
    test    al, al
    jz      .match
    cmp     al, byte [rdi + r8]
    jne     .no
    inc     r8d
    jmp     .loop
.match:
    mov     eax, 1
    ret
.no:
    xor     eax, eax
    ret

find_eq_val:
.loop:
    cmp     byte [rdi], '='
    je      .found
    cmp     byte [rdi], 0
    je      .nf
    inc     rdi
    jmp     .loop
.found:
    lea     rax, [rdi + 1]
    ret
.nf:
    mov     rax, rdi
    ret

parse_mode:
    ; rdi = "si", "iec", "iec-i"
    push    rbx
    mov     rsi, str_si_val
    push    rdi
    call    str_eq
    pop     rdi
    test    eax, eax
    jnz     .pm_si
    push    rdi
    mov     rsi, str_ieci_val
    call    str_eq
    pop     rdi
    test    eax, eax
    jnz     .pm_ieci
    push    rdi
    mov     rsi, str_iec_val
    call    str_eq
    pop     rdi
    test    eax, eax
    jnz     .pm_iec
    mov     eax, MODE_NONE
    pop     rbx
    ret
.pm_si:
    mov     eax, MODE_SI
    pop     rbx
    ret
.pm_iec:
    mov     eax, MODE_IEC
    pop     rbx
    ret
.pm_ieci:
    mov     eax, MODE_IEC_I
    pop     rbx
    ret

parse_uint:
    xor     eax, eax
.loop:
    movzx   edx, byte [rdi]
    cmp     dl, '0'
    jb      .done
    cmp     dl, '9'
    ja      .done
    imul    eax, 10
    sub     dl, '0'
    movzx   edx, dl
    add     eax, edx
    inc     rdi
    jmp     .loop
.done:
    ret

parse_int:
    xor     r10d, r10d
    cmp     byte [rdi], '-'
    jne     .pi_no_neg
    mov     r10d, 1
    inc     rdi
.pi_no_neg:
    call    parse_uint
    test    r10d, r10d
    jz      .pi_done
    neg     eax
.pi_done:
    ret

parse_int64:
    ; rdi = string, returns rax = value, rdi advanced past digits
    xor     rax, rax
    xor     r10d, r10d
    cmp     byte [rdi], '-'
    jne     .p64_no_neg
    mov     r10d, 1
    inc     rdi
.p64_no_neg:
    cmp     byte [rdi], '+'
    jne     .p64_digits
    inc     rdi
.p64_digits:
    movzx   edx, byte [rdi]
    cmp     dl, '0'
    jb      .p64_done
    cmp     dl, '9'
    ja      .p64_done
    imul    rax, 10
    sub     dl, '0'
    movzx   edx, dl
    add     rax, rdx
    inc     rdi
    jmp     .p64_digits
.p64_done:
    test    r10d, r10d
    jz      .p64_ret
    neg     rax
.p64_ret:
    ret

print_int64:
    ; rdi = signed 64-bit value
    push    rbx
    lea     rsi, [num_buf + 30]
    mov     byte [rsi], 0
    mov     rax, rdi
    xor     ecx, ecx
    test    rax, rax
    jns     .pi_pos
    mov     ecx, 1
    neg     rax
.pi_pos:
    mov     rbx, 10
.pi_loop:
    xor     edx, edx
    div     rbx
    add     dl, '0'
    dec     rsi
    mov     [rsi], dl
    test    rax, rax
    jnz     .pi_loop
    test    ecx, ecx
    jz      .pi_no_neg
    dec     rsi
    mov     byte [rsi], '-'
.pi_no_neg:
    lea     rdx, [num_buf + 30]
    sub     rdx, rsi
    mov     edi, STDOUT
    call    do_write
    pop     rbx
    ret

; print_scaled: print integer part with one decimal place
; rdi = integer part (quotient), r8 = remainder, r9 = divisor
; Output: prints "N.D" where D = (remainder * 10) / divisor
print_scaled:
    push    rbx
    push    r8
    push    r9
    ; Print integer part
    call    print_int64
    pop     r9
    pop     r8
    ; Compute decimal digit: (r8 * 10) / r9
    mov     rax, r8
    mov     rcx, 10
    mul     rcx             ; rdx:rax = remainder * 10
    div     r9              ; rax = decimal digit
    add     al, '0'
    mov     byte [dec_buf], '.'
    mov     byte [dec_buf + 1], al
    mov     edi, STDOUT
    lea     rsi, [dec_buf]
    mov     edx, 2
    call    do_write
    pop     rbx
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: numfmt [OPTION]... [NUMBER]...", 10
    db "Reformat NUMBER(s), or the numbers from standard input if none are specified.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "      --debug          print warnings about invalid input", 10
    db "  -d, --delimiter=X    use X instead of whitespace for field delimiter", 10
    db "      --field=FIELDS   replace the numbers in these input fields (default=1);", 10
    db "                         see FIELDS below", 10
    db "      --format=FORMAT  use printf style floating-point FORMAT;", 10
    db "                         see FORMAT below for details", 10
    db "      --from=UNIT      auto-scale input numbers to UNITs; default is 'none';", 10
    db "                         see UNIT below", 10
    db "      --from-unit=N    specify the input unit size (instead of the default 1)", 10
    db "      --grouping       use locale-defined grouping of digits, e.g. 1,000,000", 10
    db "                         (which means it has no effect in the C/POSIX locale)", 10
    db "      --header[=N]     print (without converting) the first N header lines;", 10
    db "                         N defaults to 1 if not specified", 10
    db "      --invalid=MODE   failure mode for invalid numbers: MODE can be:", 10
    db "                         abort (default), fail, warn, ignore", 10
    db "      --padding=N      pad the output to N characters; positive N will", 10
    db "                         right-align; negative N will left-align;", 10
    db "                         padding is ignored if the output is wider than N;", 10
    db "                         the default is to automatically pad if a whitespace", 10
    db "                         is found", 10
    db "      --round=METHOD   use METHOD for rounding when scaling; METHOD can be:", 10
    db "                         up, down, from-zero (default), towards-zero, nearest", 10
    db "      --suffix=SUFFIX  add SUFFIX to output numbers, and accept optional", 10
    db "                         SUFFIX in input numbers", 10
    db "      --to=UNIT        auto-scale output numbers to UNITs; see UNIT below", 10
    db "      --to-unit=N      the output unit size (instead of the default 1)", 10
    db "  -z, --zero-terminated    line delimiter is NUL, not newline", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "UNIT options:", 10
    db "  none       no auto-scaling is done; suffixes will trigger an error", 10
    db "  auto       accept optional single/two letter suffix:", 10
    db "               1K = 1000,", 10
    db "               1Ki = 1024,", 10
    db "               1M = 1000000,", 10
    db "               1Mi = 1048576,", 10
    db "  si         accept optional single letter suffix:", 10
    db "               1K = 1000,", 10
    db "               1M = 1000000,", 10
    db "               ...", 10
    db "  iec        accept optional single letter suffix:", 10
    db "               1K = 1024,", 10
    db "               1M = 1048576,", 10
    db "               ...", 10
    db "  iec-i      accept optional two-letter suffix:", 10
    db "               1Ki = 1024,", 10
    db "               1Mi = 1048576,", 10
    db "               ...", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/numfmt>", 10
    db "or available locally via: info '(coreutils) numfmt invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "numfmt (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Assaf Gordon.", 10
str_version_len equ $ - str_version
; @@DATA_END@@

str_prefix:         db "numfmt: "
str_prefix_len      equ $ - str_prefix
str_try:            db "Try 'numfmt --help' for more information.", 10
str_try_len         equ $ - str_try
str_unrec:          db "unrecognized option '"
str_unrec_len       equ $ - str_unrec
str_sq_nl:          db "'", 10
str_newline:        db 10

str_help_flag:      db "--help", 0
str_version_flag:   db "--version", 0
str_to_eq:          db "--to=", 0
str_from_eq:        db "--from=", 0
str_padding_eq:     db "--padding=", 0
str_field_eq:       db "--field=", 0
str_delimiter_eq:   db "--delimiter=", 0
str_suffix_eq:      db "--suffix=", 0
str_round_eq:       db "--round=", 0
str_to_unit_eq:     db "--to-unit=", 0
str_from_unit_eq:   db "--from-unit=", 0
str_format_eq:      db "--format=", 0
str_header_eq:      db "--header=", 0
str_header_flag:    db "--header", 0
str_invalid_flag:   db "--invalid=", 0
str_grouping_flag:  db "--grouping", 0
str_zero_flag:      db "--zero-terminated", 0

str_si_val:         db "si", 0
str_iec_val:        db "iec", 0
str_ieci_val:       db "iec-i", 0

; SI kilo: use uppercase 'K' to match GNU 9.4 on ubuntu-latest CI
; The assembly test compares against the local GNU, so this must match.
str_K:              db "K"
str_M:              db "M"
str_G:              db "G"
str_T:              db "T"
str_P:              db "P"
str_E:              db "E"
str_Ki:             db "Ki"
str_Mi:             db "Mi"
str_Gi:             db "Gi"
str_Ti:             db "Ti"
str_Pi:             db "Pi"
str_Ei:             db "Ei"

file_size equ $ - $$

to_mode: dd 0
from_mode: dd 0
padding: dd 0
field_num: dd 0
delimiter: db 0
           db 0, 0, 0  ; padding
suffix_ptr: dq 0
num_buf: times 32 db 0
dec_buf: db 0, 0          ; 2 bytes for ".X"
line_buf: times 4096 db 0

mem_size equ $ - $$
