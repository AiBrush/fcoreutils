; ============================================================================
;  fcomm_unified.asm — GNU-compatible "comm" in x86_64 Linux assembly
;
;  Unified flat binary: nasm -f bin, hand-crafted ELF header, no linker.
;  SSE2 SIMD line comparison, mmap zero-copy, large output buffer.
;
;  BUILD:
;    nasm -f bin fcomm_unified.asm -o fcomm && chmod +x fcomm
; ============================================================================

BITS 64
ORG 0x400000

; --- Syscall numbers ---
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_FSTAT           5
%define SYS_MMAP            9
%define SYS_MUNMAP         11
%define SYS_RT_SIGACTION   13
%define SYS_MREMAP         25
%define SYS_MADVISE        28
%define SYS_EXIT           60

%define STDIN               0
%define STDOUT              1
%define STDERR              2
%define O_RDONLY            0
%define SIGPIPE            13

; --- Buffer/mmap constants ---
%define OUT_BUF_SIZE    1048576         ; 1MB output buffer
%define FLUSH_THRESHOLD 786432          ; Flush at 768KB
%define STDIN_BUF_SIZE  16777216        ; 16MB stdin buffer
%define MAX_DELIM_LEN   256

%define PROT_READ       1
%define PROT_WRITE      2
%define MAP_PRIVATE     2
%define MAP_ANONYMOUS   0x20
%define MAP_POPULATE    0x08000
%define MADV_SEQUENTIAL 2
%define MREMAP_MAYMOVE  1

; Order check modes
%define ORDER_DEFAULT   0
%define ORDER_STRICT    1
%define ORDER_NONE      2

; --- ELF Header (64 bytes) ---
ehdr:
    db 0x7f, 'E','L','F'
    db 2, 1, 1, 0
    dq 0
    dw 2
    dw 0x3e
    dd 1
    dq _start
    dq phdr - $$
    dq 0
    dd 0
    dw ehdr_size
    dw phdr_size
    dw 2
    dw 64
    dw 0
    dw 0
ehdr_size equ $ - ehdr

; --- Program Header 1: PT_LOAD ---
phdr:
    dd 1                        ; PT_LOAD
    dd 7                        ; PF_R | PF_W | PF_X
    dq 0
    dq $$
    dq $$
    dq file_size
    dq mem_size
    dq 0x200000
phdr_size equ $ - phdr

; --- Program Header 2: PT_GNU_STACK ---
    dd 0x6474E551
    dd 6
    dq 0, 0, 0, 0, 0
    dq 0x10

; ===============================================================
; INLINED I/O ROUTINES
; ===============================================================

asm_write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.awa_loop:
    test    r13, r13
    jle     .awa_ok
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      .awa_loop
    test    rax, rax
    js      .awa_err
    add     r12, rax
    sub     r13, rax
    jmp     .awa_loop
.awa_ok:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.awa_err:
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

asm_open:
    mov     rax, SYS_OPEN
    syscall
    ret

asm_close:
    mov     rax, SYS_CLOSE
    syscall
    ret

; ===============================================================
; CODE
; ===============================================================

_start:
    ; Set up SIGPIPE to SIG_DFL (default = terminate)
    mov     rax, SYS_RT_SIGACTION
    mov     rdi, SIGPIPE
    lea     rsi, [sigact_buf]
    xor     rdx, rdx
    mov     r10, 8
    syscall

    ; Parse argc/argv from stack
    mov     r14, [rsp]              ; argc
    lea     r15, [rsp + 8]          ; argv[0]

    ; Initialize options to defaults
    mov     byte [opt_suppress1], 0
    mov     byte [opt_suppress2], 0
    mov     byte [opt_suppress3], 0
    mov     byte [opt_order_check], ORDER_DEFAULT
    mov     byte [opt_total], 0
    mov     byte [opt_zero_terminated], 0
    mov     qword [opt_delim_len], 0
    mov     byte [opt_delim_set], 0
    mov     qword [file1_path], 0
    mov     qword [file2_path], 0

    ; Parse arguments (skip argv[0])
    mov     rbx, 1
    xor     ecx, ecx
    mov     [seen_dashdash], cl

.parse_loop:
    cmp     rbx, r14
    jge     .parse_done

    mov     rsi, [r15 + rbx*8]

    cmp     byte [seen_dashdash], 0
    jne     .is_operand

    cmp     byte [rsi], '-'
    jne     .is_operand
    cmp     byte [rsi+1], 0
    je      .is_operand

    cmp     byte [rsi+1], '-'
    je      .long_option

    lea     rdi, [rsi + 1]
    jmp     .parse_short_opts

.parse_short_opts:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .parse_next

    cmp     al, '1'
    je      .short_1
    cmp     al, '2'
    je      .short_2
    cmp     al, '3'
    je      .short_3
    cmp     al, 'z'
    je      .short_z

    push    rdi
    mov     rsi, [r15 + rbx*8]
    call    err_invalid_option
    pop     rdi
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.short_1:
    mov     byte [opt_suppress1], 1
    inc     rdi
    jmp     .parse_short_opts

.short_2:
    mov     byte [opt_suppress2], 1
    inc     rdi
    jmp     .parse_short_opts

.short_3:
    mov     byte [opt_suppress3], 1
    inc     rdi
    jmp     .parse_short_opts

.short_z:
    mov     byte [opt_zero_terminated], 1
    inc     rdi
    jmp     .parse_short_opts

.long_option:
    cmp     byte [rsi+2], 0
    je      .set_dashdash

    push    rbx
    lea     rdi, [str_help_opt]
    call    strcmp
    test    eax, eax
    jz      .do_help

    mov     rsi, [r15 + rbx*8]
    lea     rdi, [str_version_opt]
    call    strcmp
    test    eax, eax
    jz      .do_version

    mov     rsi, [r15 + rbx*8]
    lea     rdi, [str_check_order_opt]
    call    strcmp
    test    eax, eax
    jz      .long_check_order

    mov     rsi, [r15 + rbx*8]
    lea     rdi, [str_nocheck_order_opt]
    call    strcmp
    test    eax, eax
    jz      .long_nocheck_order

    mov     rsi, [r15 + rbx*8]
    lea     rdi, [str_outdelim_prefix]
    mov     rcx, 19
    call    strncmp
    test    eax, eax
    jz      .long_outdelim

    mov     rsi, [r15 + rbx*8]
    lea     rdi, [str_outdelim_opt]
    call    strcmp
    test    eax, eax
    jz      .long_outdelim_space

    mov     rsi, [r15 + rbx*8]
    lea     rdi, [str_total_opt]
    call    strcmp
    test    eax, eax
    jz      .long_total

    mov     rsi, [r15 + rbx*8]
    lea     rdi, [str_zeroterm_opt]
    call    strcmp
    test    eax, eax
    jz      .long_zeroterm

    pop     rbx
    push    rbx
    mov     rsi, [r15 + rbx*8]
    call    err_unrecognized_option
    pop     rbx
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.do_help:
    pop     rbx
    mov     rdi, STDOUT
    lea     rsi, [help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

.do_version:
    pop     rbx
    mov     rdi, STDOUT
    lea     rsi, [version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

.long_check_order:
    pop     rbx
    mov     byte [opt_order_check], ORDER_STRICT
    jmp     .parse_next

.long_nocheck_order:
    pop     rbx
    mov     byte [opt_order_check], ORDER_NONE
    jmp     .parse_next

.long_outdelim:
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rsi+19]
    call    copy_output_delimiter
    mov     byte [opt_delim_set], 1
    pop     rbx
    jmp     .parse_next

.long_outdelim_space:
    pop     rbx
    inc     rbx
    cmp     rbx, r14
    jge     .err_missing_delim_arg
    mov     rdi, [r15 + rbx*8]
    call    copy_output_delimiter
    mov     byte [opt_delim_set], 1
    jmp     .parse_next

.long_total:
    pop     rbx
    mov     byte [opt_total], 1
    jmp     .parse_next

.long_zeroterm:
    pop     rbx
    mov     byte [opt_zero_terminated], 1
    jmp     .parse_next

.set_dashdash:
    mov     byte [seen_dashdash], 1
    jmp     .parse_next

.is_operand:
    cmp     qword [file1_path], 0
    je      .set_file1
    cmp     qword [file2_path], 0
    je      .set_file2
    push    rbx
    lea     rdi, [str_prefix]
    mov     rdx, str_prefix_len
    call    write_stderr
    lea     rdi, [str_extra_operand]
    mov     rdx, str_extra_operand_len
    call    write_stderr
    lea     rdi, [str_quote_open]
    mov     rdx, 1
    call    write_stderr
    mov     rsi, [r15 + rbx*8]
    mov     rdi, rsi
    call    strlen
    mov     rdx, rax
    mov     rdi, rsi
    call    write_stderr
    lea     rdi, [str_quote_nl]
    mov     rdx, 2
    call    write_stderr
    lea     rdi, [str_try_help]
    mov     rdx, str_try_help_len
    call    write_stderr
    pop     rbx
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.set_file1:
    mov     rax, [r15 + rbx*8]
    mov     [file1_path], rax
    jmp     .parse_next

.set_file2:
    mov     rax, [r15 + rbx*8]
    mov     [file2_path], rax
    jmp     .parse_next

.parse_next:
    inc     rbx
    jmp     .parse_loop

.parse_done:
    cmp     qword [file1_path], 0
    je      .err_missing_operand

    cmp     qword [file2_path], 0
    je      .err_missing_operand_after

    ; Determine line delimiter
    cmp     byte [opt_zero_terminated], 0
    jne     .use_nul_delim
    mov     byte [line_delim], 10
    jmp     .setup_delim_done
.use_nul_delim:
    mov     byte [line_delim], 0
.setup_delim_done:

    ; Setup output delimiter
    cmp     byte [opt_delim_set], 0
    jne     .delim_already_set
    mov     byte [opt_delim_buf], 9
    mov     qword [opt_delim_len], 1
.delim_already_set:

    ; Open file1
    mov     rdi, [file1_path]
    call    open_and_mmap_file
    test    rax, rax
    js      .err_open_file1
    mov     [file1_addr], rax
    mov     [file1_len], rdx

    ; Open file2
    mov     rdi, [file2_path]
    call    open_and_mmap_file
    test    rax, rax
    js      .err_open_file2
    mov     [file2_addr], rax
    mov     [file2_len], rdx

    ; Initialize counters
    mov     qword [count1], 0
    mov     qword [count2], 0
    mov     qword [count3], 0
    mov     byte [had_order_error], 0
    mov     byte [warned1], 0
    mov     byte [warned2], 0
    mov     qword [out_buf_used], 0

    ; Main merge loop
    mov     rax, [file1_addr]
    mov     [f1_base], rax
    mov     rax, [file2_addr]
    mov     [f2_base], rax

    xor     r12d, r12d
    xor     r13d, r13d
    mov     r14, [file1_len]
    mov     r15, [file2_len]

    ; Strip trailing delimiter
    test    r14, r14
    jz      .no_strip1
    mov     rax, [f1_base]
    movzx   ecx, byte [line_delim]
    cmp     byte [rax + r14 - 1], cl
    jne     .no_strip1
    dec     r14
.no_strip1:
    test    r15, r15
    jz      .no_strip2
    mov     rax, [f2_base]
    movzx   ecx, byte [line_delim]
    cmp     byte [rax + r15 - 1], cl
    jne     .no_strip2
    dec     r15
.no_strip2:

    mov     qword [prev1_ptr], 0
    mov     qword [prev1_len], 0
    mov     qword [prev2_ptr], 0
    mov     qword [prev2_len], 0
    mov     byte [has_prev1], 0
    mov     byte [has_prev2], 0

.merge_loop:
    cmp     r12, r14
    jge     .drain_file2
    cmp     r13, r15
    jge     .drain_file1

    mov     rax, [f1_base]
    lea     rdi, [rax + r12]
    mov     [cur_line1_ptr], rdi
    mov     rsi, r14
    sub     rsi, r12
    movzx   edx, byte [line_delim]
    call    find_delim
    mov     [cur_line1_len], rax

    mov     rax, [f2_base]
    lea     rdi, [rax + r13]
    mov     [cur_line2_ptr], rdi
    mov     rsi, r15
    sub     rsi, r13
    movzx   edx, byte [line_delim]
    call    find_delim
    mov     [cur_line2_len], rax

    mov     rdi, [cur_line1_ptr]
    mov     rsi, [cur_line1_len]
    mov     rdx, [cur_line2_ptr]
    mov     rcx, [cur_line2_len]
    call    compare_lines

    test    rax, rax
    js      .line1_less
    jz      .lines_equal
    jmp     .line1_greater

.line1_less:
    call    check_order_file1
    test    rax, rax
    jnz     .early_exit_order

    cmp     byte [opt_suppress1], 0
    jne     .skip_col1_output

    mov     rdi, [cur_line1_ptr]
    mov     rsi, [cur_line1_len]
    xor     edx, edx
    call    output_line

.skip_col1_output:
    inc     qword [count1]

    mov     rax, [cur_line1_ptr]
    mov     [prev1_ptr], rax
    mov     rax, [cur_line1_len]
    mov     [prev1_len], rax
    mov     byte [has_prev1], 1

    add     r12, [cur_line1_len]
    cmp     r12, r14
    jge     .merge_loop
    inc     r12
    jmp     .merge_loop

.line1_greater:
    call    check_order_file2
    test    rax, rax
    jnz     .early_exit_order

    cmp     byte [opt_suppress2], 0
    jne     .skip_col2_output

    cmp     byte [opt_suppress1], 0
    jne     .col2_no_prefix
    mov     edx, 1
    jmp     .col2_write
.col2_no_prefix:
    xor     edx, edx
.col2_write:
    mov     rdi, [cur_line2_ptr]
    mov     rsi, [cur_line2_len]
    call    output_line

.skip_col2_output:
    inc     qword [count2]

    mov     rax, [cur_line2_ptr]
    mov     [prev2_ptr], rax
    mov     rax, [cur_line2_len]
    mov     [prev2_len], rax
    mov     byte [has_prev2], 1

    add     r13, [cur_line2_len]
    cmp     r13, r15
    jge     .merge_loop
    inc     r13
    jmp     .merge_loop

.lines_equal:
    cmp     byte [opt_suppress3], 0
    jne     .skip_col3_output

    xor     edx, edx
    cmp     byte [opt_suppress1], 0
    jne     .col3_check2
    inc     edx
.col3_check2:
    cmp     byte [opt_suppress2], 0
    jne     .col3_write
    inc     edx
.col3_write:
    mov     rdi, [cur_line1_ptr]
    mov     rsi, [cur_line1_len]
    call    output_line

.skip_col3_output:
    inc     qword [count3]

    mov     rax, [cur_line1_ptr]
    mov     [prev1_ptr], rax
    mov     rax, [cur_line1_len]
    mov     [prev1_len], rax
    mov     byte [has_prev1], 1

    mov     rax, [cur_line2_ptr]
    mov     [prev2_ptr], rax
    mov     rax, [cur_line2_len]
    mov     [prev2_len], rax
    mov     byte [has_prev2], 1

    add     r12, [cur_line1_len]
    cmp     r12, r14
    jge     .adv_pos2_equal
    inc     r12
.adv_pos2_equal:
    add     r13, [cur_line2_len]
    cmp     r13, r15
    jge     .merge_loop
    inc     r13
    jmp     .merge_loop

; ─── Drain remaining file1 lines ──────────────────────────
.drain_file1:
    cmp     r12, r14
    jge     .after_drain

    mov     rax, [f1_base]
    lea     rdi, [rax + r12]
    mov     [cur_line1_ptr], rdi
    mov     rsi, r14
    sub     rsi, r12
    movzx   edx, byte [line_delim]
    call    find_delim
    mov     [cur_line1_len], rax

    call    check_order_file1
    test    rax, rax
    jnz     .early_exit_order

    cmp     byte [opt_suppress1], 0
    jne     .skip_drain1_output
    mov     rdi, [cur_line1_ptr]
    mov     rsi, [cur_line1_len]
    xor     edx, edx
    call    output_line
.skip_drain1_output:
    inc     qword [count1]

    mov     rax, [cur_line1_ptr]
    mov     [prev1_ptr], rax
    mov     rax, [cur_line1_len]
    mov     [prev1_len], rax
    mov     byte [has_prev1], 1

    add     r12, [cur_line1_len]
    cmp     r12, r14
    jge     .after_drain
    inc     r12
    jmp     .drain_file1

; ─── Drain remaining file2 lines ──────────────────────────
.drain_file2:
    cmp     r13, r15
    jge     .after_drain

    mov     rax, [f2_base]
    lea     rdi, [rax + r13]
    mov     [cur_line2_ptr], rdi
    mov     rsi, r15
    sub     rsi, r13
    movzx   edx, byte [line_delim]
    call    find_delim
    mov     [cur_line2_len], rax

    call    check_order_file2
    test    rax, rax
    jnz     .early_exit_order

    cmp     byte [opt_suppress2], 0
    jne     .skip_drain2_output
    cmp     byte [opt_suppress1], 0
    jne     .drain2_no_prefix
    mov     edx, 1
    jmp     .drain2_write
.drain2_no_prefix:
    xor     edx, edx
.drain2_write:
    mov     rdi, [cur_line2_ptr]
    mov     rsi, [cur_line2_len]
    call    output_line
.skip_drain2_output:
    inc     qword [count2]

    mov     rax, [cur_line2_ptr]
    mov     [prev2_ptr], rax
    mov     rax, [cur_line2_len]
    mov     [prev2_len], rax
    mov     byte [has_prev2], 1

    add     r13, [cur_line2_len]
    cmp     r13, r15
    jge     .after_drain
    inc     r13
    jmp     .drain_file2

.after_drain:
    cmp     byte [opt_total], 0
    je      .skip_total

    ; Format: count1 SEP count2 SEP count3 SEP "total" DELIM
    lea     rdi, [itoa_buf]
    mov     rsi, [count1]
    call    itoa_u64
    lea     rsi, [itoa_buf]
    mov     rdx, rax
    call    append_to_outbuf

    lea     rsi, [opt_delim_buf]
    mov     rdx, [opt_delim_len]
    call    append_to_outbuf

    lea     rdi, [itoa_buf]
    mov     rsi, [count2]
    call    itoa_u64
    lea     rsi, [itoa_buf]
    mov     rdx, rax
    call    append_to_outbuf

    lea     rsi, [opt_delim_buf]
    mov     rdx, [opt_delim_len]
    call    append_to_outbuf

    lea     rdi, [itoa_buf]
    mov     rsi, [count3]
    call    itoa_u64
    lea     rsi, [itoa_buf]
    mov     rdx, rax
    call    append_to_outbuf

    lea     rsi, [opt_delim_buf]
    mov     rdx, [opt_delim_len]
    call    append_to_outbuf

    lea     rsi, [str_total_word]
    mov     rdx, 5
    call    append_to_outbuf

    lea     rsi, [line_delim]
    mov     rdx, 1
    call    append_to_outbuf

.skip_total:
    call    flush_outbuf

    cmp     byte [had_order_error], 0
    je      .no_order_summary
    cmp     byte [opt_order_check], ORDER_DEFAULT
    jne     .no_order_summary
    lea     rdi, [str_input_not_sorted]
    mov     rdx, str_input_not_sorted_len
    call    write_stderr
.no_order_summary:

    cmp     byte [had_order_error], 0
    jne     .exit_1
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

.exit_1:
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.early_exit_order:
    call    flush_outbuf
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

; ─── Error handlers ───────────────────────────────────────

.err_missing_operand:
    lea     rdi, [str_missing_operand]
    mov     rdx, str_missing_operand_len
    call    write_stderr
    lea     rdi, [str_try_help]
    mov     rdx, str_try_help_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_missing_operand_after:
    lea     rdi, [str_prefix]
    mov     rdx, str_prefix_len
    call    write_stderr
    lea     rdi, [str_missing_after]
    mov     rdx, str_missing_after_len
    call    write_stderr
    lea     rdi, [str_quote_open]
    mov     rdx, 1
    call    write_stderr
    mov     rdi, [file1_path]
    mov     rsi, rdi
    call    strlen
    mov     rdx, rax
    mov     rdi, rsi
    call    write_stderr
    lea     rdi, [str_quote_nl]
    mov     rdx, 2
    call    write_stderr
    lea     rdi, [str_try_help]
    mov     rdx, str_try_help_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_missing_delim_arg:
    lea     rdi, [str_prefix]
    mov     rdx, str_prefix_len
    call    write_stderr
    lea     rdi, [str_delim_requires_arg]
    mov     rdx, str_delim_requires_arg_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_open_file1:
    mov     rdi, [file1_path]
    call    err_open_file
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_open_file2:
    mov     rdi, [file2_path]
    call    err_open_file
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

; ─── Subroutines ──────────────────────────────────────────

open_and_mmap_file:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     rbx, rdi

    cmp     byte [rdi], '-'
    jne     .omf_not_stdin
    cmp     byte [rdi+1], 0
    jne     .omf_not_stdin

    mov     r12, STDIN_BUF_SIZE
    xor     edi, edi
    mov     rsi, r12
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8d, -1
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .omf_mmap_stdin_fail
    mov     r14, rax
    xor     r13d, r13d

.omf_stdin_loop:
    mov     rdi, STDIN
    lea     rsi, [r14 + r13]
    mov     rdx, r12
    sub     rdx, r13
    cmp     rdx, STDIN_BUF_SIZE
    jbe     .omf_stdin_read_ok
    mov     rdx, STDIN_BUF_SIZE
.omf_stdin_read_ok:
    test    rdx, rdx
    jz      .omf_stdin_grow
    call    asm_read
    test    rax, rax
    jle     .omf_stdin_done
    add     r13, rax

    mov     rax, r12
    sub     rax, r13
    cmp     rax, 4096
    jge     .omf_stdin_loop

.omf_stdin_grow:
    mov     rdi, r14
    mov     rsi, r12
    lea     rdx, [r12 * 2]
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .omf_mmap_stdin_fail
    mov     r14, rax
    shl     r12, 1
    jmp     .omf_stdin_loop

.omf_stdin_done:
    mov     rax, r14
    mov     rdx, r13
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.omf_mmap_stdin_fail:
    mov     rax, -1
    xor     edx, edx
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.omf_not_stdin:
    mov     rdi, rbx
    xor     esi, esi
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .omf_open_fail
    mov     r12, rax

    sub     rsp, 144
    mov     rdi, r12
    mov     rsi, rsp
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .omf_fstat_fail

    mov     r13, [rsp + 48]
    add     rsp, 144

    test    r13, r13
    jz      .omf_empty_file

    xor     edi, edi
    mov     rsi, r13
    mov     edx, PROT_READ
    mov     r10d, MAP_PRIVATE
    or      r10d, MAP_POPULATE
    mov     r8, r12
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    test    rax, rax
    js      .omf_mmap_fail

    push    rax

    mov     rdi, rax
    mov     rsi, r13
    mov     edx, MADV_SEQUENTIAL
    mov     rax, SYS_MADVISE
    syscall

    mov     rdi, r12
    call    asm_close

    pop     rax
    mov     rdx, r13
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.omf_empty_file:
    mov     rdi, r12
    call    asm_close
    lea     rax, [stat_buf]
    xor     edx, edx
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.omf_fstat_fail:
    add     rsp, 144
.omf_open_fail:
.omf_mmap_fail:
    mov     rax, -1
    xor     edx, edx
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; find_delim
find_delim:
    push    rbx
    mov     rbx, rdi
    mov     rcx, rsi
    mov     al, dl

    movd    xmm0, edx
    punpcklbw xmm0, xmm0
    punpcklwd xmm0, xmm0
    pshufd  xmm0, xmm0, 0

    cmp     rcx, 16
    jb      .fd_byte_scan

.fd_sse_loop:
    cmp     rcx, 16
    jb      .fd_byte_scan
    movdqu  xmm1, [rdi]
    pcmpeqb xmm1, xmm0
    pmovmskb eax, xmm1
    test    eax, eax
    jnz     .fd_found_sse
    add     rdi, 16
    sub     rcx, 16
    jmp     .fd_sse_loop

.fd_found_sse:
    bsf     eax, eax
    add     rdi, rax
    sub     rdi, rbx
    mov     rax, rdi
    pop     rbx
    ret

.fd_byte_scan:
    test    rcx, rcx
    jz      .fd_not_found
    movzx   edx, byte [line_delim]
.fd_byte_loop:
    cmp     byte [rdi], dl
    je      .fd_found_byte
    inc     rdi
    dec     rcx
    jnz     .fd_byte_loop
.fd_not_found:
    mov     rax, rsi
    pop     rbx
    ret

.fd_found_byte:
    sub     rdi, rbx
    mov     rax, rdi
    pop     rbx
    ret

; compare_lines
compare_lines:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     r15, rcx

    mov     rbx, r13
    cmp     rbx, r15
    jbe     .cl_min_set
    mov     rbx, r15
.cl_min_set:

    test    rbx, rbx
    jz      .cl_compare_lengths

    mov     rdi, r12
    mov     rsi, r14
    mov     rcx, rbx

.cl_sse_loop:
    cmp     rcx, 16
    jb      .cl_byte_loop

    movdqu  xmm0, [rdi]
    movdqu  xmm1, [rsi]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0
    xor     eax, 0xFFFF
    test    eax, eax
    jnz     .cl_found_diff_sse

    add     rdi, 16
    add     rsi, 16
    sub     rcx, 16
    jmp     .cl_sse_loop

.cl_found_diff_sse:
    bsf     eax, eax
    movzx   edx, byte [rdi + rax]
    movzx   ecx, byte [rsi + rax]
    cmp     edx, ecx
    jb      .cl_less
    jmp     .cl_greater

.cl_byte_loop:
    test    rcx, rcx
    jz      .cl_compare_lengths
    movzx   eax, byte [rdi]
    movzx   edx, byte [rsi]
    cmp     eax, edx
    jb      .cl_less
    ja      .cl_greater
    inc     rdi
    inc     rsi
    dec     rcx
    jmp     .cl_byte_loop

.cl_compare_lengths:
    cmp     r13, r15
    jb      .cl_less
    ja      .cl_greater
    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.cl_less:
    mov     rax, -1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.cl_greater:
    mov     rax, 1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; output_line
output_line:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, rdi
    mov     r13, rsi
    mov     r14d, edx

    movzx   eax, r14b
    imul    rax, [opt_delim_len]
    add     rax, r13
    inc     rax
    mov     rbx, rax

    mov     rcx, [out_buf_used]
    add     rcx, rbx
    cmp     rcx, OUT_BUF_SIZE
    jb      .ol_no_flush
    call    flush_outbuf
.ol_no_flush:

    mov     rcx, [out_buf_used]
    cmp     rcx, FLUSH_THRESHOLD
    jb      .ol_write_prefix
    call    flush_outbuf

.ol_write_prefix:
    test    r14d, r14d
    jz      .ol_write_line

    lea     rsi, [opt_delim_buf]
    mov     rdx, [opt_delim_len]

.ol_prefix_loop:
    test    r14d, r14d
    jz      .ol_write_line
    call    append_to_outbuf
    dec     r14d
    jmp     .ol_prefix_loop

.ol_write_line:
    mov     rsi, r12
    mov     rdx, r13
    test    rdx, rdx
    jz      .ol_write_delim
    call    append_to_outbuf

.ol_write_delim:
    lea     rsi, [line_delim]
    mov     rdx, 1
    call    append_to_outbuf

    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; append_to_outbuf
append_to_outbuf:
    test    rdx, rdx
    jz      .atob_done
    mov     rcx, [out_buf_used]
    lea     rdi, [out_buf]
    add     rdi, rcx
    push    rsi
    push    rdx
    mov     rcx, rdx
    rep movsb
    pop     rdx
    pop     rsi
    add     [out_buf_used], rdx
.atob_done:
    ret

; flush_outbuf
flush_outbuf:
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rax, [out_buf_used]
    test    rax, rax
    jz      .fob_done
    mov     rdi, STDOUT
    lea     rsi, [out_buf]
    mov     rdx, rax
    call    asm_write_all
    test    rax, rax
    js      .fob_write_error
    mov     qword [out_buf_used], 0
.fob_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

.fob_write_error:
    lea     rdi, [str_write_error_msg]
    mov     rdx, str_write_error_msg_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

; check_order_file1
check_order_file1:
    push    rbx

    cmp     byte [opt_order_check], ORDER_NONE
    je      .cof1_ok
    cmp     byte [warned1], 0
    jne     .cof1_ok
    cmp     byte [has_prev1], 0
    je      .cof1_ok

    mov     rdi, [cur_line1_ptr]
    mov     rsi, [cur_line1_len]
    mov     rdx, [prev1_ptr]
    mov     rcx, [prev1_len]
    call    compare_lines
    test    rax, rax
    jns     .cof1_ok

    mov     byte [had_order_error], 1
    mov     byte [warned1], 1

    push    r12
    push    r13
    push    r14
    push    r15
    lea     rdi, [str_file1_not_sorted]
    mov     rdx, str_file1_not_sorted_len
    call    write_stderr
    pop     r15
    pop     r14
    pop     r13
    pop     r12

    cmp     byte [opt_order_check], ORDER_STRICT
    je      .cof1_stop

.cof1_ok:
    xor     eax, eax
    pop     rbx
    ret

.cof1_stop:
    mov     eax, 1
    pop     rbx
    ret

; check_order_file2
check_order_file2:
    push    rbx

    cmp     byte [opt_order_check], ORDER_NONE
    je      .cof2_ok
    cmp     byte [warned2], 0
    jne     .cof2_ok
    cmp     byte [has_prev2], 0
    je      .cof2_ok

    mov     rdi, [cur_line2_ptr]
    mov     rsi, [cur_line2_len]
    mov     rdx, [prev2_ptr]
    mov     rcx, [prev2_len]
    call    compare_lines
    test    rax, rax
    jns     .cof2_ok

    mov     byte [had_order_error], 1
    mov     byte [warned2], 1

    push    r12
    push    r13
    push    r14
    push    r15
    lea     rdi, [str_file2_not_sorted]
    mov     rdx, str_file2_not_sorted_len
    call    write_stderr
    pop     r15
    pop     r14
    pop     r13
    pop     r12

    cmp     byte [opt_order_check], ORDER_STRICT
    je      .cof2_stop

.cof2_ok:
    xor     eax, eax
    pop     rbx
    ret

.cof2_stop:
    mov     eax, 1
    pop     rbx
    ret

; copy_output_delimiter
copy_output_delimiter:
    push    rbx
    mov     rsi, rdi
    call    strlen
    cmp     rax, MAX_DELIM_LEN
    jbe     .cod_len_ok
    mov     rax, MAX_DELIM_LEN
.cod_len_ok:
    mov     [opt_delim_len], rax
    mov     rcx, rax
    mov     rdi, rsi
    lea     rsi, [opt_delim_buf]
    push    rdi
    mov     rdi, rsi
    pop     rsi
    rep movsb
    pop     rbx
    ret

; itoa_u64
itoa_u64:
    push    rbx
    push    r12
    mov     r12, rdi
    mov     rax, rsi

    test    rax, rax
    jnz     .itoa_nonzero
    mov     byte [r12], '0'
    mov     rax, 1
    pop     r12
    pop     rbx
    ret

.itoa_nonzero:
    lea     rbx, [itoa_tmp]
    xor     ecx, ecx

.itoa_loop:
    test    rax, rax
    jz      .itoa_reverse
    xor     edx, edx
    mov     r8, 10
    div     r8
    add     dl, '0'
    mov     [rbx + rcx], dl
    inc     ecx
    jmp     .itoa_loop

.itoa_reverse:
    mov     eax, ecx
    dec     ecx
.itoa_rev_loop:
    test    ecx, ecx
    js      .itoa_done
    movzx   edx, byte [rbx + rcx]
    mov     [r12], dl
    inc     r12
    dec     ecx
    jmp     .itoa_rev_loop

.itoa_done:
    pop     r12
    pop     rbx
    ret

; strcmp
strcmp:
.loop:
    movzx   eax, byte [rdi]
    movzx   edx, byte [rsi]
    cmp     al, dl
    jne     .ne
    test    al, al
    jz      .eq
    inc     rdi
    inc     rsi
    jmp     .loop
.eq:
    xor     eax, eax
    ret
.ne:
    sub     eax, edx
    ret

; strncmp
strncmp:
    test    rcx, rcx
    jz      .sn_eq
.sn_loop:
    movzx   eax, byte [rdi]
    movzx   edx, byte [rsi]
    cmp     al, dl
    jne     .sn_ne
    inc     rdi
    inc     rsi
    dec     rcx
    jnz     .sn_loop
.sn_eq:
    xor     eax, eax
    ret
.sn_ne:
    sub     eax, edx
    ret

; strlen
strlen:
    mov     rsi, rdi
.sl_loop:
    cmp     byte [rdi], 0
    je      .sl_done
    inc     rdi
    jmp     .sl_loop
.sl_done:
    mov     rax, rdi
    sub     rax, rsi
    ret

; write_stderr
write_stderr:
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rsi, rdi
    mov     rdi, STDERR
    call    asm_write_all
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

; err_invalid_option
err_invalid_option:
    push    rsi
    lea     rdi, [str_invalid_opt]
    mov     rdx, str_invalid_opt_len
    call    write_stderr
    pop     rsi
    mov     rdi, rsi
    push    rdi
    call    strlen
    pop     rdi
    mov     rdx, rax
    call    write_stderr
    lea     rdi, [str_quote_nl]
    mov     rdx, 2
    call    write_stderr
    lea     rdi, [str_try_help]
    mov     rdx, str_try_help_len
    call    write_stderr
    ret

; err_unrecognized_option
err_unrecognized_option:
    push    rsi
    lea     rdi, [str_unrecognized]
    mov     rdx, str_unrecognized_len
    call    write_stderr
    pop     rsi
    mov     rdi, rsi
    push    rdi
    call    strlen
    pop     rdi
    mov     rdx, rax
    call    write_stderr
    lea     rdi, [str_quote_nl]
    mov     rdx, 2
    call    write_stderr
    lea     rdi, [str_try_help]
    mov     rdx, str_try_help_len
    call    write_stderr
    ret

; err_open_file
err_open_file:
    push    rdi
    lea     rdi, [str_prefix]
    mov     rdx, str_prefix_len
    call    write_stderr
    pop     rdi
    push    rdi
    mov     rsi, rdi
    call    strlen
    pop     rdi
    mov     rdx, rax
    call    write_stderr
    lea     rdi, [str_colon_space]
    mov     rdx, 2
    call    write_stderr
    lea     rdi, [str_enoent]
    mov     rdx, str_enoent_len
    call    write_stderr
    lea     rdi, [str_newline]
    mov     rdx, 1
    call    write_stderr
    ret

; ===============================================================
; DATA
; ===============================================================

align 16
sigact_buf:
    dq 0            ; sa_handler = SIG_DFL
    dq 0x04000000   ; sa_flags = SA_RESTORER
    dq 0            ; sa_restorer
    dq 0            ; sa_mask

str_prefix:     db "comm: "
str_prefix_len equ $ - str_prefix

str_newline:    db 10
str_colon_space: db ": "
str_quote_open: db 27h
str_quote_nl:   db 27h, 10

str_help_opt:       db "--help", 0
str_version_opt:    db "--version", 0
str_check_order_opt: db "--check-order", 0
str_nocheck_order_opt: db "--nocheck-order", 0
str_outdelim_prefix: db "--output-delimiter=", 0
str_outdelim_opt:   db "--output-delimiter", 0
str_total_opt:      db "--total", 0
str_zeroterm_opt:   db "--zero-terminated", 0

str_total_word:     db "total"

str_missing_operand: db "comm: missing operand", 10
str_missing_operand_len equ $ - str_missing_operand

str_missing_after:  db "missing operand after "
str_missing_after_len equ $ - str_missing_after

str_extra_operand:  db "extra operand "
str_extra_operand_len equ $ - str_extra_operand

str_delim_requires_arg: db "option '--output-delimiter' requires an argument", 10
str_delim_requires_arg_len equ $ - str_delim_requires_arg

str_write_error_msg: db "comm: write error", 10
str_write_error_msg_len equ $ - str_write_error_msg

str_file1_not_sorted: db "comm: file 1 is not in sorted order", 10
str_file1_not_sorted_len equ $ - str_file1_not_sorted

str_file2_not_sorted: db "comm: file 2 is not in sorted order", 10
str_file2_not_sorted_len equ $ - str_file2_not_sorted

str_input_not_sorted: db "comm: input is not in sorted order", 10
str_input_not_sorted_len equ $ - str_input_not_sorted

str_unrecognized:   db "comm: unrecognized option ", 27h
str_unrecognized_len equ $ - str_unrecognized

str_try_help: db "Try 'comm --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_invalid_opt: db "comm: invalid option -- ", 27h
str_invalid_opt_len equ $ - str_invalid_opt

str_enoent: db "No such file or directory"
str_enoent_len equ $ - str_enoent

help_text:
    db "Usage: comm [OPTION]... FILE1 FILE2", 10
    db "Compare sorted files FILE1 and FILE2 line by line.", 10
    db 10
    db "When FILE1 or FILE2 (not both) is -, read standard input.", 10
    db 10
    db "With no options, produce three-column output.  Column one contains", 10
    db "lines unique to FILE1, column two contains lines unique to FILE2,", 10
    db "and column three contains lines common to both files.", 10
    db 10
    db "  -1                      suppress column 1 (lines unique to FILE1)", 10
    db "  -2                      suppress column 2 (lines unique to FILE2)", 10
    db "  -3                      suppress column 3 (lines that appear in both files)", 10
    db 10
    db "      --check-order       check that the input is correctly sorted, even", 10
    db "                            if all input lines are pairable", 10
    db "      --nocheck-order     do not check that the input is correctly sorted", 10
    db "      --output-delimiter=STR  separate columns with STR", 10
    db "      --total             output a summary", 10
    db "  -z, --zero-terminated   line delimiter is NUL, not newline", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
help_text_len equ $ - help_text

version_text:
    db "comm (fcoreutils) 0.1.0", 10
version_text_len equ $ - version_text

; ===============================================================
; BSS (uninitialized data — zero-filled by ELF loader)
; ===============================================================
file_size equ $ - $$

bss_base        equ $$ + file_size

; Options
opt_suppress1       equ bss_base + 0           ; 1
opt_suppress2       equ bss_base + 1           ; 1
opt_suppress3       equ bss_base + 2           ; 1
opt_order_check     equ bss_base + 3           ; 1
opt_total           equ bss_base + 4           ; 1
opt_zero_terminated equ bss_base + 5           ; 1
opt_delim_set       equ bss_base + 6           ; 1
seen_dashdash       equ bss_base + 7           ; 1
line_delim          equ bss_base + 8           ; 1

opt_delim_len       equ bss_base + 16          ; 8
opt_delim_buf       equ bss_base + 24          ; MAX_DELIM_LEN = 256

file1_path          equ bss_base + 280         ; 8
file2_path          equ bss_base + 288         ; 8
file1_addr          equ bss_base + 296         ; 8
file1_len           equ bss_base + 304         ; 8
file2_addr          equ bss_base + 312         ; 8
file2_len           equ bss_base + 320         ; 8

f1_base             equ bss_base + 328         ; 8
f2_base             equ bss_base + 336         ; 8

cur_line1_ptr       equ bss_base + 344         ; 8
cur_line1_len       equ bss_base + 352         ; 8
cur_line2_ptr       equ bss_base + 360         ; 8
cur_line2_len       equ bss_base + 368         ; 8

prev1_ptr           equ bss_base + 376         ; 8
prev1_len           equ bss_base + 384         ; 8
prev2_ptr           equ bss_base + 392         ; 8
prev2_len           equ bss_base + 400         ; 8
has_prev1           equ bss_base + 408         ; 1
has_prev2           equ bss_base + 409         ; 1
warned1             equ bss_base + 410         ; 1
warned2             equ bss_base + 411         ; 1
had_order_error     equ bss_base + 412         ; 1

count1              equ bss_base + 416         ; 8
count2              equ bss_base + 424         ; 8
count3              equ bss_base + 432         ; 8

out_buf_used        equ bss_base + 440         ; 8

stat_buf            equ bss_base + 448         ; 144

itoa_buf            equ bss_base + 592         ; 32
itoa_tmp            equ bss_base + 624         ; 32

out_buf             equ bss_base + 672         ; OUT_BUF_SIZE = 1048576

bss_end             equ out_buf + OUT_BUF_SIZE
mem_size            equ bss_end - $$
