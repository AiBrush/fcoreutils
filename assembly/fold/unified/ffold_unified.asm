; ============================================================================
;  ffold_unified.asm — Unified single-file build of ffold
;  Auto-merged from modular source — DO NOT EDIT
;  Edit tools/ffold.asm and rebuild instead
;  Build: nasm -f bin unified/ffold_unified.asm -o ffold_tiny && chmod +x ffold_tiny
; ============================================================================

BITS 64
org 0x400000

; ── Linux syscall numbers and constants ──
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_FSTAT           5
%define SYS_MMAP            9
%define SYS_MUNMAP         11
%define SYS_RT_SIGPROCMASK 14
%define SYS_EXIT           60

%define STDIN               0
%define STDOUT              1
%define STDERR              2
%define O_RDONLY            0
%define SIGPIPE            13
%define SIG_BLOCK           0
%define EINTR              -4
%define EPIPE             -32

; ── Constants ──
%define READ_BUF_SIZE   131072
%define OUT_BUF_SIZE    524288
%define FLUSH_THRESHOLD 262144
%define MAX_FILES       256
%define DEFAULT_WIDTH   80

; ── Macros ──
%macro EXIT 1
    mov     rax, SYS_EXIT
    mov     rdi, %1
    syscall
%endmacro

%macro BLOCK_SIGPIPE 0
    sub     rsp, 16
    mov     qword [rsp], (1 << (SIGPIPE - 1))
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16
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
    dw      2
    dw      0, 0, 0
ehdr_end:

; ── Program Headers ──
phdr:
    ; PT_LOAD: Code + Data + BSS (RWX)
    dd      1                       ; PT_LOAD
    dd      7                       ; PF_R | PF_W | PF_X
    dq      0                       ; offset
    dq      0x400000                ; virtual address
    dq      0x400000                ; physical address
    dq      file_size               ; file size
    dq      file_size + bss_size    ; memory size (includes BSS)
    dq      0x1000                  ; alignment
phdr_size equ $ - phdr

    ; PT_GNU_STACK (NX)
    dd      0x6474E551
    dd      6                       ; PF_R | PF_W (no execute)
    dq      0, 0, 0, 0, 0
    dq      0x10

; ============================================================================
;                           CODE SECTION
; ============================================================================

_start:
    BLOCK_SIGPIPE

    mov     ecx, [rsp]
    lea     r14, [rsp + 8]

    xor     ebp, ebp
    xor     r12d, r12d
    mov     dword [width], DEFAULT_WIDTH
    mov     byte [flag_bytes], 0
    mov     byte [flag_spaces], 0
    mov     dword [num_files], 0

    lea     rbx, [r14 + 8]
    dec     ecx
    mov     [argc_rem], ecx
    mov     byte [past_dashdash], 0

.parse_loop:
    mov     ecx, [argc_rem]
    test    ecx, ecx
    jle     .parse_done
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .parse_done

    cmp     byte [past_dashdash], 1
    je      .add_file

    cmp     byte [rsi], '-'
    jne     .add_file
    cmp     byte [rsi + 1], 0
    je      .add_file

    cmp     byte [rsi + 1], '-'
    je      .check_long

    inc     rsi
    call    parse_short_options
    jmp     .next_arg

.check_long:
    cmp     byte [rsi + 2], 0
    jne     .long_opt
    mov     byte [past_dashdash], 1
    jmp     .next_arg

.long_opt:
    call    parse_long_option
    jmp     .next_arg

.add_file:
    mov     eax, [num_files]
    cmp     eax, MAX_FILES
    jge     .next_arg
    mov     [files + rax*8], rsi
    inc     eax
    mov     [num_files], eax
    jmp     .next_arg

.next_arg:
    add     rbx, 8
    dec     dword [argc_rem]
    jmp     .parse_loop

.parse_done:
    mov     eax, [num_files]
    test    eax, eax
    jnz     .process_files

    mov     edi, STDIN
    call    process_fd
    jmp     .final_flush

.process_files:
    xor     r13d, r13d
.file_loop:
    cmp     r13d, [num_files]
    jge     .final_flush

    mov     rsi, [files + r13*8]

    cmp     byte [rsi], '-'
    jne     .open_file
    cmp     byte [rsi + 1], 0
    jne     .open_file
    push    r13
    mov     edi, STDIN
    call    process_fd
    pop     r13
    jmp     .next_file

.open_file:
    push    r13
    call    open_and_process
    pop     r13

.next_file:
    inc     r13d
    jmp     .file_loop

.final_flush:
    call    flush_output
    test    eax, eax
    jnz     .write_error_exit

    movzx   rdi, bpl
    EXIT    rdi

.write_error_exit:
    mov     rdi, str_write_error
    call    print_error_msg
    mov     rdi, 1
    EXIT    rdi

; ============================================================================
parse_short_options:
    push    rbx

.pso_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .pso_done

    cmp     al, 'b'
    je      .pso_bytes
    cmp     al, 's'
    je      .pso_spaces
    cmp     al, 'w'
    je      .pso_width
    jmp     .pso_invalid

.pso_bytes:
    mov     byte [flag_bytes], 1
    inc     rsi
    jmp     .pso_loop

.pso_spaces:
    mov     byte [flag_spaces], 1
    inc     rsi
    jmp     .pso_loop

.pso_width:
    inc     rsi
    movzx   eax, byte [rsi]
    test    al, al
    jz      .pso_width_next_arg
    cmp     al, '0'
    jl      .pso_width_next_arg
    cmp     al, '9'
    jg      .pso_width_next_arg
    push    rsi
    call    parse_number
    test    eax, eax
    js      .pso_invalid_width_inline
    mov     [width], eax
    add     rsp, 8
    jmp     .pso_loop

.pso_invalid_width_inline:
    pop     rsi
    call    print_invalid_width
    mov     rdi, 1
    EXIT    rdi

.pso_width_next_arg:
    pop     rbx
    add     rbx, 8
    dec     dword [argc_rem]
    cmp     dword [argc_rem], 0
    jle     .pso_missing_width
    mov     rsi, [rbx]
    push    rsi
    push    rbx
    call    parse_number
    pop     rbx
    test    eax, eax
    js      .pso_invalid_width_nextarg
    mov     [width], eax
    add     rsp, 8
    push    rbx
    jmp     .pso_done

.pso_invalid_width_nextarg:
    pop     rsi
    call    print_invalid_width
    mov     rdi, 1
    EXIT    rdi

.pso_missing_width:
    mov     rdi, str_prefix
    mov     edx, str_prefix_len
    call    write_stderr
    mov     rdi, str_w_requires_arg
    mov     edx, str_w_requires_arg_len
    call    write_stderr
    mov     rdi, str_newline
    mov     edx, 1
    call    write_stderr
    mov     rdi, str_try_help
    mov     edx, str_try_help_len
    call    write_stderr
    mov     rdi, 1
    EXIT    rdi

.pso_invalid:
    mov     [opt_char_buf], al
    mov     rdi, str_invalid_opt
    mov     edx, str_invalid_opt_len
    call    write_stderr
    mov     rdi, opt_char_buf
    mov     edx, 1
    call    write_stderr
    mov     rdi, str_quote_nl
    mov     edx, 2
    call    write_stderr
    mov     rdi, str_try_help
    mov     edx, str_try_help_len
    call    write_stderr
    mov     rdi, 1
    EXIT    rdi

.pso_done:
    pop     rbx
    ret

; ============================================================================
parse_long_option:
    push    rbx

    mov     rdi, str_dashdash_help
    call    strcmp
    test    eax, eax
    jz      .plo_help

    mov     rsi, [rbx]
    mov     rdi, str_dashdash_version
    call    strcmp
    test    eax, eax
    jz      .plo_version

    mov     rsi, [rbx]
    mov     rdi, str_dashdash_bytes
    call    strcmp
    test    eax, eax
    jz      .plo_bytes

    mov     rsi, [rbx]
    mov     rdi, str_dashdash_spaces
    call    strcmp
    test    eax, eax
    jz      .plo_spaces

    mov     rsi, [rbx]
    mov     rdi, str_dashdash_width_eq
    mov     ecx, 8
    call    strncmp
    test    eax, eax
    jz      .plo_width_eq

    mov     rsi, [rbx]
    mov     rdi, str_dashdash_width
    call    strcmp
    test    eax, eax
    jz      .plo_width_sep

    mov     rsi, [rbx]
    jmp     .plo_unrecognized

.plo_help:
    call    flush_output
    mov     rdi, STDOUT
    mov     rsi, help_text
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    EXIT    rdi

.plo_version:
    call    flush_output
    mov     rdi, STDOUT
    mov     rsi, version_text
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    EXIT    rdi

.plo_bytes:
    mov     byte [flag_bytes], 1
    pop     rbx
    ret

.plo_spaces:
    mov     byte [flag_spaces], 1
    pop     rbx
    ret

.plo_width_eq:
    mov     rsi, [rbx]
    add     rsi, 8
    cmp     byte [rsi], 0
    je      .plo_width_invalid
    push    rsi
    call    parse_number
    test    eax, eax
    js      .plo_width_invalid_pop
    mov     [width], eax
    add     rsp, 8
    pop     rbx
    ret

.plo_width_invalid_pop:
    pop     rsi
.plo_width_invalid:
    call    print_invalid_width
    mov     rdi, 1
    EXIT    rdi

.plo_width_sep:
    pop     rbx
    add     rbx, 8
    dec     dword [argc_rem]
    cmp     dword [argc_rem], 0
    jle     .plo_width_missing
    mov     rsi, [rbx]
    push    rsi
    push    rbx
    call    parse_number
    pop     rbx
    test    eax, eax
    js      .plo_width_sep_invalid
    mov     [width], eax
    add     rsp, 8
    push    rbx
    pop     rbx
    ret

.plo_width_sep_invalid:
    pop     rsi
    call    print_invalid_width
    mov     rdi, 1
    EXIT    rdi

.plo_width_missing:
    mov     rdi, str_prefix
    mov     edx, str_prefix_len
    call    write_stderr
    mov     rdi, str_width_requires_arg
    mov     edx, str_width_requires_arg_len
    call    write_stderr
    mov     rdi, str_newline
    mov     edx, 1
    call    write_stderr
    mov     rdi, str_try_help
    mov     edx, str_try_help_len
    call    write_stderr
    mov     rdi, 1
    EXIT    rdi

.plo_unrecognized:
    mov     rdi, str_unrecognized
    mov     edx, str_unrecognized_len
    call    write_stderr
    mov     rsi, [rbx]
    push    rsi
    mov     rdi, rsi
    call    strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, rsi
    call    write_stderr_buf
    mov     rdi, str_quote_nl
    mov     edx, 2
    call    write_stderr
    mov     rdi, str_try_help
    mov     edx, str_try_help_len
    call    write_stderr
    mov     rdi, 1
    EXIT    rdi

; ============================================================================
parse_number:
    xor     eax, eax
    movzx   edx, byte [rsi]
    cmp     dl, '0'
    jl      .pn_bad
    cmp     dl, '9'
    jg      .pn_bad
.pn_loop:
    movzx   edx, byte [rsi]
    cmp     dl, '0'
    jl      .pn_check
    cmp     dl, '9'
    jg      .pn_check
    imul    eax, 10
    jo      .pn_bad
    sub     edx, '0'
    add     eax, edx
    jo      .pn_bad
    inc     rsi
    jmp     .pn_loop
.pn_check:
    test    dl, dl
    jnz     .pn_bad
    test    eax, eax
    jz      .pn_bad
    ret
.pn_bad:
    mov     eax, -1
    ret

; ============================================================================
print_invalid_width:
    push    rbx
    mov     rbx, rsi

    mov     rdi, str_prefix
    mov     edx, str_prefix_len
    call    write_stderr

    mov     rdi, str_invalid_width_pre
    mov     edx, str_invalid_width_pre_len
    call    write_stderr

    mov     rdi, rbx
    call    strlen
    mov     edx, eax
    mov     rdi, rbx
    call    write_stderr

    mov     rdi, str_invalid_width_suf
    mov     edx, str_invalid_width_suf_len
    call    write_stderr

    pop     rbx
    ret

; ============================================================================
open_and_process:
    push    rbx
    mov     rbx, rsi

    mov     rdi, rsi
    xor     esi, esi
    xor     edx, edx
    mov     rax, SYS_OPEN
    syscall
    test    rax, rax
    js      .oap_error

    push    rax
    mov     edi, eax
    call    process_fd
    pop     rdi
    mov     rax, SYS_CLOSE
    syscall
    pop     rbx
    ret

.oap_error:
    neg     rax
    mov     edi, eax
    mov     rsi, rbx
    call    err_open_file
    mov     ebp, 1
    pop     rbx
    ret

; ============================================================================
;  process_fd — Core fold algorithm
; ============================================================================
process_fd:
    push    rbx
    push    r14
    push    r15
    push    r13

    mov     ebx, edi
    xor     r14d, r14d
    mov     r15, -1
    xor     r13d, r13d

.pf_read_loop:
    mov     edi, ebx
    mov     rsi, read_buf
    mov     edx, READ_BUF_SIZE
    call    asm_read
    test    rax, rax
    js      .pf_read_error
    jz      .pf_done

    xor     r8d, r8d
    mov     r9, rax

    cmp     byte [flag_bytes], 0
    jne     .pf_byte_loop

; ── Column mode ──
.pf_col_loop:
    cmp     r8, r9
    jge     .pf_read_loop

    movzx   eax, byte [read_buf + r8]

    cmp     al, 10
    je      .pf_col_newline
    cmp     al, 8
    je      .pf_col_backspace
    cmp     al, 13
    je      .pf_col_cr
    cmp     al, 9
    je      .pf_col_tab

    lea     edx, [r14d + 1]
    mov     ecx, [width]
    cmp     edx, ecx
    jle     .pf_col_regular_ok

    call    fold_line

.pf_col_regular_ok:
    inc     r14d

    cmp     byte [flag_spaces], 0
    je      .pf_col_regular_emit
    cmp     byte [read_buf + r8], ' '
    jne     .pf_col_regular_emit
    lea     rax, [r12 + 1]
    mov     r15, rax
    mov     r13d, r14d

.pf_col_regular_emit:
    mov     al, [read_buf + r8]
    mov     [out_buf + r12], al
    inc     r12

    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_col_next
    call    flush_output_safe
    jmp     .pf_col_next

.pf_col_next:
    inc     r8
    jmp     .pf_col_loop

.pf_col_newline:
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_col_nl_next
    call    flush_output_safe
.pf_col_nl_next:
    inc     r8
    jmp     .pf_col_loop

.pf_col_backspace:
    test    r14d, r14d
    jz      .pf_col_bs_emit
    dec     r14d
.pf_col_bs_emit:
    mov     byte [out_buf + r12], 8
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_col_bs_next
    call    flush_output_safe
.pf_col_bs_next:
    inc     r8
    jmp     .pf_col_loop

.pf_col_cr:
    xor     r14d, r14d
    mov     byte [out_buf + r12], 13
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_col_cr_next
    call    flush_output_safe
.pf_col_cr_next:
    inc     r8
    jmp     .pf_col_loop

.pf_col_tab:
    mov     eax, r14d
    add     eax, 8
    and     eax, ~7

    mov     ecx, [width]
    cmp     eax, ecx
    jle     .pf_col_tab_no_prefold
    test    r14d, r14d
    jz      .pf_col_tab_no_prefold

    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1
    mov     eax, 8

.pf_col_tab_no_prefold:
    mov     r14d, eax

    cmp     byte [flag_spaces], 0
    je      .pf_col_tab_emit
    lea     rax, [r12 + 1]
    mov     r15, rax
    mov     r13d, r14d

.pf_col_tab_emit:
    mov     byte [out_buf + r12], 9
    inc     r12

    mov     ecx, [width]
    cmp     r14d, ecx
    jle     .pf_col_tab_no_fold

    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1

.pf_col_tab_no_fold:
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_col_tab_next
    call    flush_output_safe
.pf_col_tab_next:
    inc     r8
    jmp     .pf_col_loop

; ── Byte mode ──
.pf_byte_loop:
    cmp     r8, r9
    jge     .pf_read_loop

    movzx   eax, byte [read_buf + r8]

    cmp     al, 10
    je      .pf_byte_newline

    lea     edx, [r14d + 1]
    mov     ecx, [width]
    cmp     edx, ecx
    jle     .pf_byte_ok

    call    fold_line

.pf_byte_ok:
    inc     r14d

    cmp     byte [flag_spaces], 0
    je      .pf_byte_emit
    movzx   eax, byte [read_buf + r8]
    cmp     al, ' '
    je      .pf_byte_mark_blank
    cmp     al, 9
    je      .pf_byte_mark_blank
    jmp     .pf_byte_emit

.pf_byte_mark_blank:
    lea     rax, [r12 + 1]
    mov     r15, rax
    mov     r13d, r14d

.pf_byte_emit:
    mov     al, [read_buf + r8]
    mov     [out_buf + r12], al
    inc     r12

    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_byte_next
    call    flush_output_safe
.pf_byte_next:
    inc     r8
    jmp     .pf_byte_loop

.pf_byte_newline:
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_byte_nl_next
    call    flush_output_safe
.pf_byte_nl_next:
    inc     r8
    jmp     .pf_byte_loop

.pf_read_error:
    mov     ebp, 1
.pf_done:
    pop     r13
    pop     r15
    pop     r14
    pop     rbx
    ret

; ============================================================================
fold_line:
    cmp     byte [flag_spaces], 0
    je      .fl_hard
    cmp     r15, -1
    je      .fl_hard

    mov     rax, r12
    sub     rax, r15

    lea     rdx, [r12 + 1]
    cmp     rdx, OUT_BUF_SIZE
    jge     .fl_hard

    test    rax, rax
    jz      .fl_space_insert

    lea     rdi, [out_buf + r12]
    lea     rsi, [out_buf + r12 - 1]
    mov     rcx, rax
.fl_shift:
    mov     dl, [rsi]
    mov     [rdi], dl
    dec     rsi
    dec     rdi
    dec     rcx
    jnz     .fl_shift

.fl_space_insert:
    mov     byte [out_buf + r15], 10
    inc     r12

    sub     r14d, r13d
    mov     r15, -1
    ret

.fl_hard:
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1
    ret

; ============================================================================
flush_output_safe:
    call    flush_output
    test    eax, eax
    jnz     .fos_error
    mov     r15, -1
    ret
.fos_error:
    mov     ebp, 1
    mov     r15, -1
    ret

; ============================================================================
flush_output:
    test    r12, r12
    jz      .fo_nothing
    mov     rdi, STDOUT
    mov     rsi, out_buf
    mov     rdx, r12
    call    asm_write_all
    xor     r12d, r12d
    ret
.fo_nothing:
    xor     eax, eax
    ret

; ============================================================================
;  I/O library (inlined from lib/io.asm)
; ============================================================================
asm_write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.awa_loop:
    test    r13, r13
    jle     .awa_success
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      .awa_loop
    test    rax, rax
    js      .awa_error
    add     r12, rax
    sub     r13, rax
    jmp     .awa_loop
.awa_success:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.awa_error:
    mov     rax, -1
    pop     r13
    pop     r12
    pop     rbx
    ret

asm_read:
.ar_retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, -4
    je      .ar_retry
    ret

; ============================================================================
;  String helpers
; ============================================================================
strcmp:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .sc_ne
    test    al, al
    jz      .sc_eq
    inc     rdi
    inc     rsi
    jmp     strcmp
.sc_eq:
    xor     eax, eax
    ret
.sc_ne:
    mov     eax, 1
    ret

strncmp:
    test    ecx, ecx
    jz      .sn_eq
.sn_loop:
    movzx   eax, byte [rdi]
    movzx   edx, byte [rsi]
    cmp     al, dl
    jne     .sn_ne
    inc     rdi
    inc     rsi
    dec     ecx
    jnz     .sn_loop
.sn_eq:
    xor     eax, eax
    ret
.sn_ne:
    mov     eax, 1
    ret

strlen:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; ============================================================================
;  Error helpers
; ============================================================================
write_stderr:
    mov     rsi, rdi
    mov     rdi, STDERR
    mov     edx, edx
    call    asm_write_all
    ret

write_stderr_buf:
    mov     rsi, rdi
    mov     rdi, STDERR
    call    asm_write_all
    ret

print_error_msg:
    push    rbx
    mov     rbx, rdi
    mov     rdi, str_prefix
    mov     edx, str_prefix_len
    call    write_stderr
    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, rbx
    call    write_stderr_buf
    mov     rdi, str_newline
    mov     edx, 1
    call    write_stderr
    pop     rbx
    ret

err_open_file:
    push    rbx
    push    r13
    mov     r13d, edi
    mov     rbx, rsi

    mov     rdi, str_prefix
    mov     edx, str_prefix_len
    call    write_stderr

    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, rbx
    call    write_stderr_buf

    mov     rdi, str_colon_space
    mov     edx, 2
    call    write_stderr

    mov     edi, r13d
    call    strerror
    mov     rbx, rax
    mov     rdi, rax
    call    strlen
    mov     rdx, rax
    mov     rdi, rbx
    call    write_stderr_buf

    mov     rdi, str_newline
    mov     edx, 1
    call    write_stderr

    pop     r13
    pop     rbx
    ret

strerror:
    cmp     edi, 2
    je      .se_enoent
    cmp     edi, 13
    je      .se_eacces
    cmp     edi, 21
    je      .se_eisdir
    mov     rax, str_eunknown
    ret
.se_enoent:
    mov     rax, str_enoent
    ret
.se_eacces:
    mov     rax, str_eacces
    ret
.se_eisdir:
    mov     rax, str_eisdir
    ret

; ============================================================================
;  Data Section
; ============================================================================

str_prefix:             db "fold: "
str_prefix_len equ $ - str_prefix

str_newline:            db 10
str_colon_space:        db ": "

str_dashdash_help:      db "--help", 0
str_dashdash_version:   db "--version", 0
str_dashdash_bytes:     db "--bytes", 0
str_dashdash_spaces:    db "--spaces", 0
str_dashdash_width:     db "--width", 0
str_dashdash_width_eq:  db "--width=", 0

str_unrecognized:       db "fold: unrecognized option '", 0
str_unrecognized_len equ $ - str_unrecognized - 1

str_invalid_opt:        db "fold: invalid option -- '", 0
str_invalid_opt_len equ $ - str_invalid_opt - 1

str_quote_nl:           db "'", 10

str_try_help:           db "Try 'fold --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_w_requires_arg:     db "option requires an argument -- 'w'"
str_w_requires_arg_len equ $ - str_w_requires_arg

str_width_requires_arg: db "option '--width' requires an argument"
str_width_requires_arg_len equ $ - str_width_requires_arg

str_invalid_width_pre:  db "invalid number of columns: '", 0
str_invalid_width_pre_len equ $ - str_invalid_width_pre - 1

str_invalid_width_suf:  db "': Numerical result out of range", 10
str_invalid_width_suf_len equ $ - str_invalid_width_suf

str_write_error:        db "write error", 0

; @@DATA_START@@
help_text:
    db "Usage: fold [OPTION]... [FILE]...", 10
    db "Wrap input lines in each FILE, writing to standard output.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -b, --bytes         count bytes rather than columns", 10
    db "  -s, --spaces        break at spaces", 10
    db "  -w, --width=WIDTH   use WIDTH columns instead of 80", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/fold>", 10
    db "or available locally via: info '(coreutils) fold invocation'", 10
help_text_len equ $ - help_text

version_text:
    db "fold (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by David MacKenzie.", 10
version_text_len equ $ - version_text
; @@DATA_END@@

str_enoent:         db "No such file or directory", 0
str_eacces:         db "Permission denied", 0
str_eisdir:         db "Is a directory", 0
str_eunknown:       db "Unknown error", 0

; ============================================================================
;  End of file content — compute file_size
; ============================================================================
file_size equ $ - $$

; ============================================================================
;  BSS Section (EQU offsets — not emitted into binary)
;  The kernel zeros memory between p_filesz and p_memsz at load time.
; ============================================================================
bss_base equ $$ + file_size

; 4-byte aligned variables
width           equ bss_base + 0       ; resd 1 (4 bytes)
argc_rem        equ bss_base + 4       ; resd 1 (4 bytes)
flag_bytes      equ bss_base + 8       ; resb 1
flag_spaces     equ bss_base + 9       ; resb 1
past_dashdash   equ bss_base + 10      ; resb 1
opt_char_buf    equ bss_base + 11      ; resb 2

; Align to 4 for num_files (offset 13 -> pad to 16)
num_files       equ bss_base + 16      ; resd 1 (4 bytes)

; Align to 8 for files array (offset 20 -> pad to 24)
files           equ bss_base + 24      ; resq MAX_FILES (256 * 8 = 2048)

read_buf        equ bss_base + 2072    ; resb READ_BUF_SIZE (131072)
out_buf         equ bss_base + 133144  ; resb OUT_BUF_SIZE (524288)

bss_size equ 133144 + OUT_BUF_SIZE     ; = 657432
