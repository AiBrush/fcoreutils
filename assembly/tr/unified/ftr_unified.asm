; ============================================================================
;  ftr_unified.asm — GNU-compatible "tr" in x86_64 Linux assembly
;  Unified single-file build with hand-crafted ELF header
;
;  BUILD:
;    nasm -f bin ftr_unified.asm -o ftr && chmod +x ftr
;
;  This is the merged single-file version. For development, edit the modular
;  source files in tools/ and lib/ instead.
; ============================================================================

BITS 64
org 0x400000

; ── Constants ──
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_EXIT           60
%define SYS_RT_SIGPROCMASK 14

%define STDIN               0
%define STDOUT              1
%define STDERR              2

%define EINTR              -4
%define EPIPE             -32

%define BUF_SIZE        65536

%define FLAG_COMPLEMENT  1
%define FLAG_DELETE       2
%define FLAG_SQUEEZE      4
%define FLAG_TRUNCATE     8

; ── BSS addresses (at 0x500000, zero-filled by kernel) ──
%define BSS_BASE        0x500000
%define read_buf        BSS_BASE
%define write_buf       (BSS_BASE + BUF_SIZE)
%define set1_expanded   (BSS_BASE + BUF_SIZE*2)
%define set2_expanded   (BSS_BASE + BUF_SIZE*2 + 8192)
%define translate_table (BSS_BASE + BUF_SIZE*2 + 16384)
%define member_set      (BSS_BASE + BUF_SIZE*2 + 16384 + 256)
%define squeeze_set     (BSS_BASE + BUF_SIZE*2 + 16384 + 256 + 32)
%define set1_len_var    (BSS_BASE + BUF_SIZE*2 + 16384 + 256 + 64)
%define set2_len_var    (BSS_BASE + BUF_SIZE*2 + 16384 + 256 + 72)
%define has_ssse3_var   (BSS_BASE + BUF_SIZE*2 + 16384 + 256 + 80)
%define BSS_SIZE        (BUF_SIZE*2 + 16384 + 256 + 128)

; ── Macros ──
%macro WRITE_SC 3
    mov     rax, SYS_WRITE
    mov     rdi, %1
    mov     rsi, %2
    mov     rdx, %3
    syscall
%endmacro

%macro EXIT_SC 1
    mov     rax, SYS_EXIT
    mov     rdi, %1
    syscall
%endmacro

; ── ELF Header ──
ehdr:
    db      0x7f, "ELF"
    db      2, 1, 1, 0
    dq      0
    dw      2
    dw      0x3E
    dd      1
    dq      _start
    dq      phdr - ehdr
    dq      0
    dd      0
    dw      ehdr_end - ehdr
    dw      phdr_size
    dw      3
    dw      0, 0, 0
ehdr_end:

; ── Program Headers ──
phdr:
    ; Segment 1: Code + Data (R+X)
    dd      1                       ; PT_LOAD
    dd      5                       ; PF_R | PF_X
    dq      0                       ; p_offset
    dq      0x400000                ; p_vaddr
    dq      0x400000                ; p_paddr
    dq      file_end - ehdr         ; p_filesz
    dq      file_end - ehdr         ; p_memsz
    dq      0x1000                  ; p_align
phdr_size equ $ - phdr

    ; Segment 2: BSS (R+W)
    dd      1                       ; PT_LOAD
    dd      6                       ; PF_R | PF_W
    dq      0
    dq      BSS_BASE
    dq      BSS_BASE
    dq      0                       ; p_filesz = 0
    dq      BSS_SIZE                ; p_memsz
    dq      0x1000

    ; Segment 3: GNU_STACK (NX)
    dd      0x6474E551              ; PT_GNU_STACK
    dd      6                       ; PF_R | PF_W (no X)
    dq      0, 0, 0, 0, 0
    dq      0x10

; ============================================================================
;                           CODE SECTION
; ============================================================================

_start:
    mov     r15, rsp

    ; Block SIGPIPE
    sub     rsp, 16
    mov     qword [rsp], 0x1000
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    ; Detect SSSE3
    mov     eax, 1
    cpuid
    bt      ecx, 9
    setc    byte [has_ssse3_var]

    ; Parse arguments
    mov     rsp, r15
    pop     rcx
    mov     rsi, rsp
    dec     ecx
    lea     rsi, [rsi + 8]

    xor     r12d, r12d              ; flags
    xor     r13, r13                ; set1_ptr
    xor     r14, r14                ; set2_ptr
    xor     ebx, ebx                ; positional count

    test    ecx, ecx
    jz      .args_done

.parse_loop:
    mov     rdi, [rsi]
    cmp     byte [rdi], '-'
    jne     .positional_arg
    cmp     byte [rdi+1], 0
    je      .positional_arg
    cmp     byte [rdi+1], '-'
    je      .long_option

    ; Short options
    lea     rdi, [rdi + 1]
.short_opt_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_arg
    cmp     al, 'c'
    je      .flag_c
    cmp     al, 'C'
    je      .flag_c
    cmp     al, 'd'
    je      .flag_d
    cmp     al, 's'
    je      .flag_s
    cmp     al, 't'
    je      .flag_t
    jmp     .err_invalid_opt

.flag_c: or r12d, FLAG_COMPLEMENT
    inc rdi
    jmp .short_opt_loop
.flag_d: or r12d, FLAG_DELETE
    inc rdi
    jmp .short_opt_loop
.flag_s: or r12d, FLAG_SQUEEZE
    inc rdi
    jmp .short_opt_loop
.flag_t: or r12d, FLAG_TRUNCATE
    inc rdi
    jmp .short_opt_loop

.long_option:
    mov     rdi, [rsi]
    cmp     byte [rdi+2], 0
    je      .end_of_options
    lea     rax, [rdi + 2]

    ; --help
    cmp     dword [rax], 'help'
    jne     .chk_ver
    cmp     byte [rax+4], 0
    je      .do_help

.chk_ver:
    cmp     dword [rax], 'vers'
    jne     .chk_comp
    cmp     dword [rax+4], 'ion' | (0 << 24)
    jne     .chk_comp
    jmp     .do_version

.chk_comp:
    cmp     dword [rax], 'comp'
    jne     .chk_del
    cmp     dword [rax+4], 'leme'
    jne     .chk_del
    cmp     word [rax+8], 'nt'
    jne     .chk_del
    cmp     byte [rax+10], 0
    jne     .chk_del
    or      r12d, FLAG_COMPLEMENT
    jmp     .next_arg

.chk_del:
    cmp     dword [rax], 'dele'
    jne     .chk_sq
    cmp     word [rax+4], 'te'
    jne     .chk_sq
    cmp     byte [rax+6], 0
    jne     .chk_sq
    or      r12d, FLAG_DELETE
    jmp     .next_arg

.chk_sq:
    cmp     dword [rax], 'sque'
    jne     .chk_trunc
    cmp     dword [rax+4], 'eze-'
    jne     .chk_trunc
    cmp     dword [rax+8], 'repe'
    jne     .chk_trunc
    cmp     dword [rax+12], 'ats' | (0 << 24)
    jne     .chk_trunc
    or      r12d, FLAG_SQUEEZE
    jmp     .next_arg

.chk_trunc:
    cmp     dword [rax], 'trun'
    jne     .err_unrecognized
    cmp     dword [rax+4], 'cate'
    jne     .err_unrecognized
    cmp     dword [rax+8], '-set'
    jne     .err_unrecognized
    cmp     word [rax+12], '1' | (0 << 8)
    jne     .err_unrecognized
    or      r12d, FLAG_TRUNCATE
    jmp     .next_arg

.positional_arg:
    test    ebx, ebx
    jnz     .store_s2
    mov     r13, rdi
    inc     ebx
    jmp     .next_arg
.store_s2:
    cmp     ebx, 1
    jne     .store_extra
    mov     r14, rdi
    inc     ebx
    jmp     .next_arg
.store_extra:
    cmp     ebx, 2
    jne     .store_extra_skip
    mov     rbp, rdi
.store_extra_skip:
    inc     ebx
    jmp     .next_arg

.end_of_options:
    add     rsi, 8
    dec     ecx
.eo_loop:
    test    ecx, ecx
    jz      .args_done
    mov     rdi, [rsi]
    test    ebx, ebx
    jnz     .eo_s2
    mov     r13, rdi
    inc     ebx
    jmp     .eo_next
.eo_s2:
    cmp     ebx, 1
    jne     .eo_extra
    mov     r14, rdi
    inc     ebx
    jmp     .eo_next
.eo_extra:
    cmp     ebx, 2
    jne     .eo_extra_skip
    mov     rbp, rdi
.eo_extra_skip:
    inc     ebx
.eo_next:
    add     rsi, 8
    dec     ecx
    jmp     .eo_loop

.next_arg:
    add     rsi, 8
    dec     ecx
    jnz     .parse_loop

.args_done:
    test    ebx, ebx
    jz      .err_no_operand

    ; Dispatch
    test    r12d, FLAG_DELETE
    jnz     .mode_del
    test    r12d, FLAG_SQUEEZE
    jnz     .mode_sq
    cmp     ebx, 2
    jl      .err_missing_set2_tr
    jg      .err_extra_general
    jmp     do_translate

.mode_del:
    test    r12d, FLAG_SQUEEZE
    jnz     .mode_ds
    cmp     ebx, 2
    jge     .err_extra_del
    jmp     do_delete

.mode_ds:
    cmp     ebx, 2
    jl      .err_missing_set2_ds
    jg      .err_extra_general
    jmp     do_delete_squeeze

.mode_sq:
    cmp     ebx, 2
    jg      .err_extra_general
    jge     do_translate_squeeze
    jmp     do_squeeze

; ── Error Handlers ──
.err_no_operand:
    WRITE_SC STDERR, err_missing_operand, err_missing_operand_len
    WRITE_SC STDERR, err_try_help, err_try_help_len
    EXIT_SC 1

.err_missing_set2_tr:
    WRITE_SC STDERR, err_missing_after, err_missing_after_len
    mov     rdi, r13
    call    strlen
    mov     r15, rax
    WRITE_SC STDERR, r13, r15
    WRITE_SC STDERR, err_quote_nl, err_quote_nl_len
    WRITE_SC STDERR, err_two_tr, err_two_tr_len
    WRITE_SC STDERR, err_try_help, err_try_help_len
    EXIT_SC 1

.err_missing_set2_ds:
    WRITE_SC STDERR, err_missing_after, err_missing_after_len
    mov     rdi, r13
    call    strlen
    mov     r15, rax
    WRITE_SC STDERR, r13, r15
    WRITE_SC STDERR, err_quote_nl, err_quote_nl_len
    WRITE_SC STDERR, err_two_ds, err_two_ds_len
    WRITE_SC STDERR, err_try_help, err_try_help_len
    EXIT_SC 1

.err_extra_del:
    WRITE_SC STDERR, err_extra, err_extra_len
    mov     rdi, r14
    call    strlen
    mov     r15, rax
    WRITE_SC STDERR, r14, r15
    WRITE_SC STDERR, err_quote_nl, err_quote_nl_len
    WRITE_SC STDERR, err_one_del, err_one_del_len
    WRITE_SC STDERR, err_try_help, err_try_help_len
    EXIT_SC 1

.err_extra_general:
    ; rbp = pointer to the extra (3rd) operand
    WRITE_SC STDERR, err_extra, err_extra_len
    mov     rdi, rbp
    call    strlen
    mov     r15, rax
    WRITE_SC STDERR, rbp, r15
    WRITE_SC STDERR, err_quote_nl, err_quote_nl_len
    WRITE_SC STDERR, err_try_help, err_try_help_len
    EXIT_SC 1

.err_invalid_opt:
    push    rax
    WRITE_SC STDERR, err_invalid, err_invalid_len
    lea     rsi, [rsp]
    WRITE_SC STDERR, rsi, 1
    WRITE_SC STDERR, err_quote_nl, err_quote_nl_len
    pop     rax
    WRITE_SC STDERR, err_try_help, err_try_help_len
    EXIT_SC 1

.err_unrecognized:
    mov     rbx, rdi
    WRITE_SC STDERR, err_unrec, err_unrec_len
    mov     rdi, rbx
    call    strlen
    mov     r15, rax
    WRITE_SC STDERR, rbx, r15
    WRITE_SC STDERR, err_quote_nl, err_quote_nl_len
    WRITE_SC STDERR, err_try_help, err_try_help_len
    EXIT_SC 1

.do_help:
    WRITE_SC STDOUT, help_text, help_text_len
    EXIT_SC 0

.do_version:
    WRITE_SC STDOUT, version_text, version_text_len
    EXIT_SC 0

; ── Utility: strlen(rdi) -> rax ──
strlen:
    push    rcx
    mov     rcx, rdi
.sl:
    cmp     byte [rcx], 0
    je      .sl_done
    inc     rcx
    jmp     .sl
.sl_done:
    sub     rcx, rdi
    mov     rax, rcx
    pop     rcx
    ret

; ── I/O: asm_write_all(rdi=fd, rsi=buf, rdx=len) -> rax ──
asm_write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.wa_loop:
    test    r13, r13
    jle     .wa_ok
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, EINTR
    je      .wa_loop
    test    rax, rax
    js      .wa_err
    add     r12, rax
    sub     r13, rax
    jmp     .wa_loop
.wa_ok:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.wa_err:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── I/O: asm_read(rdi=fd, rsi=buf, rdx=len) -> rax ──
asm_read:
.rd_retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, EINTR
    je      .rd_retry
    ret

; ── Range error handler (called from parse_set) ──
; ecx = start char, edx = end char of the reversed range
err_range_reversed:
    sub     rsp, 8
    mov     byte [rsp], cl
    mov     byte [rsp+1], '-'
    mov     byte [rsp+2], dl
    WRITE_SC STDERR, err_range_reversed_prefix, err_range_reversed_prefix_len
    lea     rsi, [rsp]
    WRITE_SC STDERR, rsi, 3
    WRITE_SC STDERR, err_range_reversed_suffix, err_range_reversed_suffix_len
    add     rsp, 8
    EXIT_SC 1

; ============================================================================
;                       SET PARSING
; ============================================================================

; parse_set(rdi=string, rsi=output_buf) -> rax=expanded_length
parse_set:
    push    rbx
    push    r8
    push    r9
    push    r10
    push    r11

    mov     r8, rdi
    mov     r9, rsi
    mov     rbx, rsi

.ps_loop:
    ; Bounds check: stop if output buffer is full
    lea     rax, [r9]
    sub     rax, rbx
    cmp     rax, 8192
    jge     .ps_done

    movzx   eax, byte [r8]
    test    al, al
    jz      .ps_done
    cmp     al, '['
    je      .ps_bracket
    cmp     al, '\'
    je      .ps_escape

    ; Regular char — check range
    mov     r10b, al
    inc     r8
    cmp     byte [r8], '-'
    jne     .ps_emit
    cmp     byte [r8+1], 0
    je      .ps_emit
    inc     r8
    call    .ps_get_char
    mov     r11b, al
    movzx   ecx, r10b
    movzx   edx, r11b
    cmp     ecx, edx
    jg      err_range_reversed
.ps_range:
    lea     rax, [r9]
    sub     rax, rbx
    cmp     rax, 8192
    jge     .ps_done
    mov     [r9], cl
    inc     r9
    inc     ecx
    cmp     ecx, edx
    jle     .ps_range
    jmp     .ps_loop

.ps_emit:
    mov     [r9], r10b
    inc     r9
    jmp     .ps_loop

.ps_escape:
    inc     r8
    call    .ps_get_escape
    mov     r10b, al
    cmp     byte [r8], '-'
    jne     .ps_emit
    cmp     byte [r8+1], 0
    je      .ps_emit
    inc     r8
    call    .ps_get_char
    mov     r11b, al
    movzx   ecx, r10b
    movzx   edx, r11b
    cmp     ecx, edx
    jg      err_range_reversed
    jmp     .ps_range

.ps_bracket:
    cmp     byte [r8+1], ':'
    je      .ps_class
    cmp     byte [r8+1], '='
    je      .ps_equiv
    cmp     byte [r8+2], '*'
    je      .ps_repeat
    cmp     byte [r8+1], '\'
    jne     .ps_lit_bracket
    push    r8
    lea     r8, [r8+2]
    call    .ps_get_escape
    cmp     byte [r8], '*'
    pop     r8
    je      .ps_repeat_esc
    jmp     .ps_lit_bracket

.ps_lit_bracket:
    mov     r10b, '['
    inc     r8
    cmp     byte [r8], '-'
    jne     .ps_emit
    cmp     byte [r8+1], 0
    je      .ps_emit
    inc     r8
    call    .ps_get_char
    mov     r11b, al
    movzx   ecx, r10b
    movzx   edx, r11b
    cmp     ecx, edx
    jg      err_range_reversed
    jmp     .ps_range

.ps_class:
    add     r8, 2
    mov     rdi, r8
.ps_cc_find:
    cmp     byte [r8], ':'
    jne     .ps_cc_nx
    cmp     byte [r8+1], ']'
    je      .ps_cc_found
.ps_cc_nx:
    cmp     byte [r8], 0
    je      .ps_done
    inc     r8
    jmp     .ps_cc_find
.ps_cc_found:
    mov     rcx, r8
    sub     rcx, rdi
    add     r8, 2
    call    expand_char_class
    jmp     .ps_loop

.ps_equiv:
    add     r8, 2
    call    .ps_get_char
    cmp     byte [r8], '='
    jne     .ps_loop
    cmp     byte [r8+1], ']'
    jne     .ps_loop
    add     r8, 2
    mov     [r9], al
    inc     r9
    jmp     .ps_loop

.ps_repeat:
    inc     r8
    call    .ps_get_char
    mov     r10b, al
    inc     r8
    jmp     .ps_rep_parse

.ps_repeat_esc:
    inc     r8
    call    .ps_get_char
    mov     r10b, al
    inc     r8
    jmp     .ps_rep_parse

.ps_rep_parse:
    xor     edx, edx
    movzx   eax, byte [r8]
    cmp     al, ']'
    je      .ps_rep_fill
    cmp     al, '0'
    je      .ps_rep_oct_start
    jmp     .ps_rep_dec

.ps_rep_oct_start:
    inc     r8
    movzx   eax, byte [r8]
    cmp     al, ']'
    je      .ps_rep_fill
.ps_rep_oct:
    movzx   eax, byte [r8]
    cmp     al, ']'
    je      .ps_rep_emit
    sub     al, '0'
    cmp     al, 7
    ja      .ps_rep_emit
    imul    edx, 8
    movzx   eax, al
    add     edx, eax
    inc     r8
    jmp     .ps_rep_oct

.ps_rep_dec:
    movzx   eax, byte [r8]
    cmp     al, ']'
    je      .ps_rep_emit
    sub     al, '0'
    cmp     al, 9
    ja      .ps_rep_emit
    imul    edx, 10
    movzx   eax, al
    add     edx, eax
    inc     r8
    jmp     .ps_rep_dec

.ps_rep_fill:
    mov     edx, 8192
.ps_rep_emit:
    cmp     byte [r8], ']'
    jne     .ps_rep_skip
    inc     r8
.ps_rep_skip:
    test    edx, edx
    jz      .ps_loop
    lea     rax, [r9]
    sub     rax, rbx
    add     rax, rdx
    cmp     rax, 8192
    jl      .ps_rep_loop
    mov     edx, 8192
    lea     rax, [r9]
    sub     rax, rbx
    sub     edx, eax
    test    edx, edx
    jle     .ps_loop
.ps_rep_loop:
    mov     [r9], r10b
    inc     r9
    dec     edx
    jnz     .ps_rep_loop
    jmp     .ps_loop

.ps_done:
    mov     rax, r9
    sub     rax, rbx
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rbx
    ret

; ── get_char / get_escape helpers ──
.ps_get_char:
    movzx   eax, byte [r8]
    cmp     al, '\'
    je      .ps_gc_esc
    inc     r8
    ret
.ps_gc_esc:
    inc     r8
.ps_get_escape:
    movzx   eax, byte [r8]
    inc     r8
    cmp     al, 'a'
    je      .esc_bel
    cmp     al, 'b'
    je      .esc_bs
    cmp     al, 'f'
    je      .esc_ff
    cmp     al, 'n'
    je      .esc_nl
    cmp     al, 'r'
    je      .esc_cr
    cmp     al, 't'
    je      .esc_tab
    cmp     al, 'v'
    je      .esc_vt
    cmp     al, '\'
    je      .esc_bslash
    cmp     al, '0'
    jb      .esc_lit
    cmp     al, '7'
    ja      .esc_lit
    sub     al, '0'
    movzx   edx, al
    movzx   eax, byte [r8]
    cmp     al, '0'
    jb      .esc_oct_done
    cmp     al, '7'
    ja      .esc_oct_done
    sub     al, '0'
    shl     edx, 3
    add     edx, eax
    inc     r8
    movzx   eax, byte [r8]
    cmp     al, '0'
    jb      .esc_oct_done
    cmp     al, '7'
    ja      .esc_oct_done
    sub     al, '0'
    shl     edx, 3
    add     edx, eax
    inc     r8
.esc_oct_done:
    mov     eax, edx
    and     eax, 0xFF
    ret
.esc_bel:   mov al, 7
    ret
.esc_bs:    mov al, 8
    ret
.esc_ff:    mov al, 12
    ret
.esc_nl:    mov al, 10
    ret
.esc_cr:    mov al, 13
    ret
.esc_tab:   mov al, 9
    ret
.esc_vt:    mov al, 11
    ret
.esc_bslash: mov al, '\'
    ret
.esc_lit:
    ret

; ============================================================================
;                   CHARACTER CLASS EXPANSION
; ============================================================================

%macro EMIT_RANGE 2
    mov     ecx, %1
%%loop:
    lea     rax, [r9]
    sub     rax, rbx
    cmp     rax, 8192
    jge     %%done
    mov     [r9], cl
    inc     r9
    inc     ecx
    cmp     ecx, %2 + 1
    jl      %%loop
%%done:
%endmacro

%macro EMIT_BYTE 1
    lea     rax, [r9]
    sub     rax, rbx
    cmp     rax, 8192
    jge     %%skip
    mov     byte [r9], %1
    inc     r9
%%skip:
%endmacro

; expand_char_class(rdi=name_ptr, rcx=name_len, r9=output_ptr)
expand_char_class:
    push    rbx
    push    r10
    push    r11
    push    r8

    mov     r10, rdi
    mov     r11, rcx
    lea     rbx, [cls_table]
    xor     r8d, r8d

.ecc_loop:
    cmp     r8d, 12
    jge     .ecc_done
    mov     rdi, [rbx]
    mov     rsi, r10
    mov     rcx, r11
.ecc_cmp:
    test    rcx, rcx
    jz      .ecc_chk
    movzx   eax, byte [rsi]
    cmp     al, [rdi]
    jne     .ecc_next
    inc     rsi
    inc     rdi
    dec     rcx
    jmp     .ecc_cmp
.ecc_chk:
    cmp     byte [rdi], 0
    je      .ecc_expand
.ecc_next:
    add     rbx, 16
    inc     r8d
    jmp     .ecc_loop

.ecc_expand:
    ; Restore rbx to output buffer start for EMIT bounds checks
    mov     rbx, [rsp + 24]
    cmp     r8d, 0
    je      .c_alnum
    cmp     r8d, 1
    je      .c_alpha
    cmp     r8d, 2
    je      .c_blank
    cmp     r8d, 3
    je      .c_cntrl
    cmp     r8d, 4
    je      .c_digit
    cmp     r8d, 5
    je      .c_graph
    cmp     r8d, 6
    je      .c_lower
    cmp     r8d, 7
    je      .c_print
    cmp     r8d, 8
    je      .c_punct
    cmp     r8d, 9
    je      .c_space
    cmp     r8d, 10
    je      .c_upper
    jmp     .c_xdigit

.c_alnum:
    EMIT_RANGE '0', '9'
    EMIT_RANGE 'A', 'Z'
    EMIT_RANGE 'a', 'z'
    jmp     .ecc_done
.c_alpha:
    EMIT_RANGE 'A', 'Z'
    EMIT_RANGE 'a', 'z'
    jmp     .ecc_done
.c_blank:
    EMIT_BYTE 9
    EMIT_BYTE 32
    jmp     .ecc_done
.c_cntrl:
    EMIT_RANGE 0, 31
    EMIT_BYTE 127
    jmp     .ecc_done
.c_digit:
    EMIT_RANGE '0', '9'
    jmp     .ecc_done
.c_graph:
    EMIT_RANGE 33, 126
    jmp     .ecc_done
.c_lower:
    EMIT_RANGE 'a', 'z'
    jmp     .ecc_done
.c_print:
    EMIT_RANGE 32, 126
    jmp     .ecc_done
.c_punct:
    EMIT_RANGE 33, 47
    EMIT_RANGE 58, 64
    EMIT_RANGE 91, 96
    EMIT_RANGE 123, 126
    jmp     .ecc_done
.c_space:
    EMIT_RANGE 9, 13
    EMIT_BYTE 32
    jmp     .ecc_done
.c_upper:
    EMIT_RANGE 'A', 'Z'
    jmp     .ecc_done
.c_xdigit:
    EMIT_RANGE '0', '9'
    EMIT_RANGE 'A', 'F'
    EMIT_RANGE 'a', 'f'
.ecc_done:
    pop     r8
    pop     r11
    pop     r10
    pop     rbx
    ret

; ============================================================================
;                   TABLE / SET BUILDING
; ============================================================================

build_translate_table:
    push    rbx
    push    r13
    push    r14
    push    r15

    lea     rdi, [translate_table]
    xor     ecx, ecx
.btt_init:
    mov     [rdi + rcx], cl
    inc     ecx
    cmp     ecx, 256
    jl      .btt_init

    mov     r13, [set1_len_var]
    mov     r14, [set2_len_var]

    ; Cap set lengths to 256 (max meaningful for byte-to-byte translation)
    cmp     r13, 256
    jle     .btt_s1_ok
    mov     r13, 256
.btt_s1_ok:
    cmp     r14, 256
    jle     .btt_s2_ok
    mov     r14, 256
.btt_s2_ok:

    test    r12d, FLAG_COMPLEMENT
    jz      .btt_no_comp

    sub     rsp, 32
    xor     eax, eax
    mov     [rsp], rax
    mov     [rsp+8], rax
    mov     [rsp+16], rax
    mov     [rsp+24], rax

    lea     rsi, [set1_expanded]
    xor     edx, edx
.btt_ca:
    cmp     rdx, r13
    jge     .btt_cb
    movzx   eax, byte [rsi + rdx]
    mov     ecx, eax
    and     ecx, 7
    shr     eax, 3
    mov     r15b, 1
    shl     r15b, cl
    or      [rsp + rax], r15b
    inc     rdx
    jmp     .btt_ca
.btt_cb:
    lea     rdi, [set1_expanded]
    xor     ecx, ecx
    xor     r13d, r13d
.btt_cl:
    cmp     ecx, 256
    jge     .btt_cd
    mov     eax, ecx
    and     eax, 7
    mov     edx, ecx
    shr     edx, 3
    movzx   ebx, byte [rsp + rdx]
    bt      ebx, eax
    jc      .btt_cs
    mov     [rdi + r13], cl
    inc     r13d
.btt_cs:
    inc     ecx
    cmp     ecx, 256
    jl      .btt_cl
.btt_cd:
    add     rsp, 32
    mov     [set1_len_var], r13

.btt_no_comp:
    test    r12d, FLAG_TRUNCATE
    jz      .btt_no_trunc
    cmp     r13, r14
    jle     .btt_no_trunc
    mov     r13, r14
.btt_no_trunc:

    cmp     r14, r13
    jge     .btt_ready
    test    r14, r14
    jz      .btt_ready
    lea     rsi, [set2_expanded]
    movzx   eax, byte [rsi + r14 - 1]
.btt_ext:
    cmp     r14, r13
    jge     .btt_ready
    cmp     r14, 256
    jge     .btt_ready
    mov     [rsi + r14], al
    inc     r14
    jmp     .btt_ext

.btt_ready:
    lea     rsi, [set1_expanded]
    lea     rdi, [set2_expanded]
    lea     rbx, [translate_table]
    xor     ecx, ecx
.btt_map:
    cmp     rcx, r13
    jge     .btt_done
    movzx   eax, byte [rsi + rcx]
    movzx   edx, byte [rdi + rcx]
    mov     [rbx + rax], dl
    inc     rcx
    jmp     .btt_map
.btt_done:
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; build_member_set(rsi=expanded_set, rcx=set_len, rdi=bitmap_output)
build_member_set:
    push    rax
    push    rdx
    push    rcx
    push    rbx
    push    r8

    xor     eax, eax
    mov     [rdi], rax
    mov     [rdi+8], rax
    mov     [rdi+16], rax
    mov     [rdi+24], rax

    xor     edx, edx
.bms_loop:
    cmp     rdx, rcx
    jge     .bms_comp
    movzx   eax, byte [rsi + rdx]
    mov     ebx, eax
    shr     ebx, 3
    and     eax, 7
    mov     r8b, 1
    push    rcx
    mov     ecx, eax
    shl     r8b, cl
    pop     rcx
    or      [rdi + rbx], r8b
    inc     rdx
    jmp     .bms_loop
.bms_comp:
    test    r12d, FLAG_COMPLEMENT
    jz      .bms_done
    not     qword [rdi]
    not     qword [rdi+8]
    not     qword [rdi+16]
    not     qword [rdi+24]
.bms_done:
    pop     r8
    pop     rbx
    pop     rcx
    pop     rdx
    pop     rax
    ret

; ============================================================================
;                   PROCESSING MODES
; ============================================================================

do_translate:
    mov     rdi, r13
    lea     rsi, [set1_expanded]
    call    parse_set
    mov     [set1_len_var], rax

    mov     rdi, r14
    lea     rsi, [set2_expanded]
    call    parse_set
    mov     [set2_len_var], rax

    call    build_translate_table

    cmp     byte [has_ssse3_var], 0
    je      .dt_scalar

    ; SSSE3 main loop
.dt_simd_loop:
    mov     edi, STDIN
    lea     rsi, [read_buf]
    mov     edx, BUF_SIZE
    call    asm_read
    test    rax, rax
    jz      .dt_exit0
    js      .dt_exit1

    mov     rcx, rax
    lea     rsi, [read_buf]
    lea     rbx, [translate_table]

    movdqa  xmm15, [mask_0f_data]
    xor     edx, edx

.dt_s16:
    lea     rax, [rdx + 16]
    cmp     rax, rcx
    jg      .dt_stail

    movdqu  xmm0, [rsi + rdx]
    movdqa  xmm1, xmm0
    pand    xmm1, xmm15
    movdqa  xmm2, xmm0
    psrlw   xmm2, 4
    pand    xmm2, xmm15
    pxor    xmm0, xmm0

    ; Unrolled nibble lookup for rows 0-15
%assign _h 0
%rep 16
    movdqu  xmm3, [rbx + _h*16]
    pshufb  xmm3, xmm1
    movdqa  xmm4, xmm2
    pcmpeqb xmm4, [nibble_data + _h*16]
    pand    xmm3, xmm4
    por     xmm0, xmm3
%assign _h _h+1
%endrep

    movdqu  [rsi + rdx], xmm0
    add     edx, 16
    jmp     .dt_s16

.dt_stail:
    cmp     rdx, rcx
    jge     .dt_swrite
    movzx   eax, byte [rsi + rdx]
    mov     al, [rbx + rax]
    mov     [rsi + rdx], al
    inc     edx
    jmp     .dt_stail

.dt_swrite:
    mov     edi, STDOUT
    lea     rsi, [read_buf]
    mov     rdx, rcx
    call    asm_write_all
    test    rax, rax
    js      .dt_pipe
    jmp     .dt_simd_loop

.dt_scalar:
    mov     edi, STDIN
    lea     rsi, [read_buf]
    mov     edx, BUF_SIZE
    call    asm_read
    test    rax, rax
    jz      .dt_exit0
    js      .dt_exit1

    mov     rcx, rax
    lea     rsi, [read_buf]
    lea     rbx, [translate_table]
    xor     edx, edx
.dt_sb:
    cmp     rdx, rcx
    jge     .dt_sw
    movzx   eax, byte [rsi + rdx]
    mov     al, [rbx + rax]
    mov     [rsi + rdx], al
    inc     rdx
    jmp     .dt_sb
.dt_sw:
    mov     edi, STDOUT
    lea     rsi, [read_buf]
    mov     rdx, rcx
    call    asm_write_all
    test    rax, rax
    js      .dt_pipe
    jmp     .dt_scalar

.dt_pipe:
    cmp     rax, EPIPE
    je      .dt_exit0
.dt_exit1:
    EXIT_SC 1
.dt_exit0:
    EXIT_SC 0

; ── Delete ──
do_delete:
    mov     rdi, r13
    lea     rsi, [set1_expanded]
    call    parse_set
    mov     [set1_len_var], rax

    lea     rsi, [set1_expanded]
    mov     rcx, [set1_len_var]
    lea     rdi, [member_set]
    call    build_member_set

.dd_loop:
    mov     edi, STDIN
    lea     rsi, [read_buf]
    mov     edx, BUF_SIZE
    call    asm_read
    test    rax, rax
    jz      .dd_exit0
    js      .dd_exit1

    mov     rcx, rax
    lea     rsi, [read_buf]
    lea     rdi, [write_buf]
    xor     edx, edx
    xor     r8d, r8d
.dd_b:
    cmp     rdx, rcx
    jge     .dd_flush
    movzx   eax, byte [rsi + rdx]
    push    rcx
    mov     ecx, eax
    and     ecx, 7
    mov     ebx, eax
    shr     ebx, 3
    movzx   r9d, byte [member_set + rbx]
    bt      r9d, ecx
    pop     rcx
    jc      .dd_skip
    mov     [rdi + r8], al
    inc     r8d
.dd_skip:
    inc     rdx
    jmp     .dd_b
.dd_flush:
    test    r8d, r8d
    jz      .dd_loop
    mov     edi, STDOUT
    lea     rsi, [write_buf]
    mov     edx, r8d
    call    asm_write_all
    test    rax, rax
    js      .dd_pipe
    jmp     .dd_loop
.dd_pipe:
    cmp     rax, EPIPE
    je      .dd_exit0
.dd_exit1:
    EXIT_SC 1
.dd_exit0:
    EXIT_SC 0

; ── Squeeze ──
do_squeeze:
    mov     rdi, r13
    lea     rsi, [set1_expanded]
    call    parse_set
    mov     [set1_len_var], rax

    lea     rsi, [set1_expanded]
    mov     rcx, [set1_len_var]
    lea     rdi, [squeeze_set]
    call    build_member_set

    mov     ebp, -1
.ds_loop:
    mov     edi, STDIN
    lea     rsi, [read_buf]
    mov     edx, BUF_SIZE
    call    asm_read
    test    rax, rax
    jz      .ds_exit0
    js      .ds_exit1

    mov     rcx, rax
    lea     rsi, [read_buf]
    lea     rdi, [write_buf]
    xor     edx, edx
    xor     r8d, r8d
.ds_b:
    cmp     rdx, rcx
    jge     .ds_flush
    movzx   eax, byte [rsi + rdx]
    cmp     eax, ebp
    jne     .ds_emit
    push    rcx
    mov     ecx, eax
    and     ecx, 7
    mov     ebx, eax
    shr     ebx, 3
    movzx   r9d, byte [squeeze_set + rbx]
    bt      r9d, ecx
    pop     rcx
    jc      .ds_skip
.ds_emit:
    mov     [rdi + r8], al
    inc     r8d
    mov     ebp, eax
.ds_skip:
    inc     rdx
    jmp     .ds_b
.ds_flush:
    test    r8d, r8d
    jz      .ds_loop
    mov     edi, STDOUT
    lea     rsi, [write_buf]
    mov     edx, r8d
    call    asm_write_all
    test    rax, rax
    js      .ds_pipe
    jmp     .ds_loop
.ds_pipe:
    cmp     rax, EPIPE
    je      .ds_exit0
.ds_exit1:
    EXIT_SC 1
.ds_exit0:
    EXIT_SC 0

; ── Delete + Squeeze ──
do_delete_squeeze:
    mov     rdi, r13
    lea     rsi, [set1_expanded]
    call    parse_set
    mov     [set1_len_var], rax

    mov     rdi, r14
    lea     rsi, [set2_expanded]
    call    parse_set
    mov     [set2_len_var], rax

    lea     rsi, [set1_expanded]
    mov     rcx, [set1_len_var]
    lea     rdi, [member_set]
    call    build_member_set

    push    r12
    and     r12d, ~FLAG_COMPLEMENT
    lea     rsi, [set2_expanded]
    mov     rcx, [set2_len_var]
    lea     rdi, [squeeze_set]
    call    build_member_set
    pop     r12

    mov     ebp, -1
.dds_loop:
    mov     edi, STDIN
    lea     rsi, [read_buf]
    mov     edx, BUF_SIZE
    call    asm_read
    test    rax, rax
    jz      .dds_exit0
    js      .dds_exit1

    mov     rcx, rax
    lea     rsi, [read_buf]
    lea     rdi, [write_buf]
    xor     edx, edx
    xor     r8d, r8d
.dds_b:
    cmp     rdx, rcx
    jge     .dds_flush
    movzx   eax, byte [rsi + rdx]
    push    rcx
    mov     ecx, eax
    and     ecx, 7
    mov     ebx, eax
    shr     ebx, 3
    movzx   r9d, byte [member_set + rbx]
    bt      r9d, ecx
    pop     rcx
    jc      .dds_del
    cmp     eax, ebp
    jne     .dds_emit
    push    rcx
    mov     ecx, eax
    and     ecx, 7
    mov     ebx, eax
    shr     ebx, 3
    movzx   r9d, byte [squeeze_set + rbx]
    bt      r9d, ecx
    pop     rcx
    jc      .dds_del
.dds_emit:
    mov     [rdi + r8], al
    inc     r8d
    mov     ebp, eax
.dds_del:
    inc     rdx
    jmp     .dds_b
.dds_flush:
    test    r8d, r8d
    jz      .dds_loop
    mov     edi, STDOUT
    lea     rsi, [write_buf]
    mov     edx, r8d
    call    asm_write_all
    test    rax, rax
    js      .dds_pipe
    jmp     .dds_loop
.dds_pipe:
    cmp     rax, EPIPE
    je      .dds_exit0
.dds_exit1:
    EXIT_SC 1
.dds_exit0:
    EXIT_SC 0

; ── Translate + Squeeze ──
do_translate_squeeze:
    mov     rdi, r13
    lea     rsi, [set1_expanded]
    call    parse_set
    mov     [set1_len_var], rax

    mov     rdi, r14
    lea     rsi, [set2_expanded]
    call    parse_set
    mov     [set2_len_var], rax

    call    build_translate_table

    push    r12
    and     r12d, ~FLAG_COMPLEMENT
    lea     rsi, [set2_expanded]
    mov     rcx, [set2_len_var]
    lea     rdi, [squeeze_set]
    call    build_member_set
    pop     r12

    mov     ebp, -1
.dts_loop:
    mov     edi, STDIN
    lea     rsi, [read_buf]
    mov     edx, BUF_SIZE
    call    asm_read
    test    rax, rax
    jz      .dts_exit0
    js      .dts_exit1

    mov     rcx, rax
    lea     rsi, [read_buf]
    lea     rdi, [write_buf]
    lea     rbx, [translate_table]
    xor     edx, edx
    xor     r8d, r8d
.dts_b:
    cmp     rdx, rcx
    jge     .dts_flush
    movzx   eax, byte [rsi + rdx]
    movzx   eax, byte [rbx + rax]
    cmp     eax, ebp
    jne     .dts_emit
    push    rcx
    mov     ecx, eax
    and     ecx, 7
    mov     r9d, eax
    shr     r9d, 3
    movzx   r10d, byte [squeeze_set + r9]
    bt      r10d, ecx
    pop     rcx
    jc      .dts_skip
.dts_emit:
    mov     [rdi + r8], al
    inc     r8d
    mov     ebp, eax
.dts_skip:
    inc     rdx
    jmp     .dts_b
.dts_flush:
    test    r8d, r8d
    jz      .dts_loop
    mov     edi, STDOUT
    lea     rsi, [write_buf]
    mov     edx, r8d
    call    asm_write_all
    test    rax, rax
    js      .dts_pipe
    jmp     .dts_loop
.dts_pipe:
    cmp     rax, EPIPE
    je      .dts_exit0
.dts_exit1:
    EXIT_SC 1
.dts_exit0:
    EXIT_SC 0

; ============================================================================
;                          DATA SECTION
; ============================================================================

; ── SIMD constants (must be 16-byte aligned) ──
align 16
mask_0f_data: times 16 db 0x0F

align 16
nibble_data:
%assign _i 0
%rep 16
    times 16 db _i
%assign _i _i+1
%endrep

; ── Character class names ──
cls_alnum:  db "alnum", 0
cls_alpha:  db "alpha", 0
cls_blank:  db "blank", 0
cls_cntrl:  db "cntrl", 0
cls_digit:  db "digit", 0
cls_graph:  db "graph", 0
cls_lower:  db "lower", 0
cls_print:  db "print", 0
cls_punct:  db "punct", 0
cls_space:  db "space", 0
cls_upper:  db "upper", 0
cls_xdigit: db "xdigit", 0

cls_table:
    dq cls_alnum,  0
    dq cls_alpha,  1
    dq cls_blank,  2
    dq cls_cntrl,  3
    dq cls_digit,  4
    dq cls_graph,  5
    dq cls_lower,  6
    dq cls_print,  7
    dq cls_punct,  8
    dq cls_space,  9
    dq cls_upper, 10
    dq cls_xdigit,11

; ── String constants ──
; @@DATA_START@@
help_text:
    db "Usage: tr [OPTION]... STRING1 [STRING2]", 10
    db "Translate, squeeze, and/or delete characters from standard input,", 10
    db "writing to standard output.  STRING1 and STRING2 specify arrays of", 10
    db "characters ARRAY1 and ARRAY2 that control the action.", 10
    db 10
    db "  -c, -C, --complement    use the complement of ARRAY1", 10
    db "  -d, --delete            delete characters in ARRAY1, do not translate", 10
    db "  -s, --squeeze-repeats   replace each sequence of a repeated character", 10
    db "                            that is listed in the last specified ARRAY,", 10
    db "                            with a single occurrence of that character", 10
    db "  -t, --truncate-set1     first truncate ARRAY1 to length of ARRAY2", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "ARRAYs are specified as strings of characters.  Most represent themselves.", 10
    db "Interpreted sequences are:", 10
    db 10
    db "  \NNN            character with octal value NNN (1 to 3 octal digits)", 10
    db "  \\              backslash", 10
    db "  \a              audible BEL", 10
    db "  \b              backspace", 10
    db "  \f              form feed", 10
    db "  \n              new line", 10
    db "  \r              return", 10
    db "  \t              horizontal tab", 10
    db "  \v              vertical tab", 10
    db "  CHAR1-CHAR2     all characters from CHAR1 to CHAR2 in ascending order", 10
    db "  [CHAR*]         in ARRAY2, copies of CHAR until length of ARRAY1", 10
    db "  [CHAR*REPEAT]   REPEAT copies of CHAR, REPEAT octal if starting with 0", 10
    db "  [:alnum:]       all letters and digits", 10
    db "  [:alpha:]       all letters", 10
    db "  [:blank:]       all horizontal whitespace", 10
    db "  [:cntrl:]       all control characters", 10
    db "  [:digit:]       all digits", 10
    db "  [:graph:]       all printable characters, not including space", 10
    db "  [:lower:]       all lower case letters", 10
    db "  [:print:]       all printable characters, including space", 10
    db "  [:punct:]       all punctuation characters", 10
    db "  [:space:]       all horizontal or vertical whitespace", 10
    db "  [:upper:]       all upper case letters", 10
    db "  [:xdigit:]      all hexadecimal digits", 10
    db "  [=CHAR=]        all characters which are equivalent to CHAR", 10
    db 10
    db "Translation occurs if -d is not given and both STRING1 and STRING2 appear.", 10
    db "-t is only significant when translating.  ARRAY2 is extended to length of", 10
    db "ARRAY1 by repeating its last character as necessary.  Excess characters", 10
    db "of ARRAY2 are ignored.  Character classes expand in unspecified order;", 10
    db "while translating, [:lower:] and [:upper:] may be used in pairs to", 10
    db "specify case conversion.  Squeezing occurs after translation or deletion.", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/tr>", 10
    db "or available locally via: info '(coreutils) tr invocation'", 10
help_text_len equ $ - help_text

version_text:
    db "tr (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by Jim Meyering.", 10
version_text_len equ $ - version_text

err_missing_operand:
    db "tr: missing operand", 10
err_missing_operand_len equ $ - err_missing_operand

err_missing_after:
    db "tr: missing operand after '"
err_missing_after_len equ $ - err_missing_after

err_extra:
    db "tr: extra operand ", 0xE2, 0x80, 0x98
err_extra_len equ $ - err_extra

err_invalid:
    db "tr: invalid option -- '"
err_invalid_len equ $ - err_invalid

err_unrec:
    db "tr: unrecognized option '"
err_unrec_len equ $ - err_unrec

err_try_help:
    db "Try 'tr --help' for more information.", 10
err_try_help_len equ $ - err_try_help

err_two_tr:
    db "Two strings must be given when translating.", 10
err_two_tr_len equ $ - err_two_tr

err_two_ds:
    db "Two strings must be given when both deleting and squeezing repeats.", 10
err_two_ds_len equ $ - err_two_ds

err_one_del:
    db "Only one string may be given when deleting without squeezing repeats.", 10
err_one_del_len equ $ - err_one_del

err_quote_nl:
    db "'", 10
err_quote_nl_len equ $ - err_quote_nl

err_range_reversed_prefix:
    db "tr: range-endpoints of '"
err_range_reversed_prefix_len equ $ - err_range_reversed_prefix

err_range_reversed_suffix:
    db "' are in reverse collating sequence order", 10
err_range_reversed_suffix_len equ $ - err_range_reversed_suffix
; @@DATA_END@@

file_end:
