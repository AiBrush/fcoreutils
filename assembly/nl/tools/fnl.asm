; fnl.asm — GNU-compatible "nl" in x86-64 Linux assembly
;
; A drop-in replacement for GNU coreutils `nl`. Pure x86-64 assembly,
; no libc, no dynamic linker. Handles all flags:
;   -b STYLE, -d CC, -f STYLE, -h STYLE, -i NUMBER, -l NUMBER,
;   -n FORMAT, -p, -s STRING, -v NUMBER, -w NUMBER, --help, --version
;
; Section delimiter detection (header/body/footer boundaries).
; Streaming line-by-line processing with 256KB output buffer.
; SIMD pcmpeqb+pmovmskb for fast newline scanning.
; Fast-path for default options: mmap + inline number formatting + SIMD copy.
;
; Register conventions (global state):
;   r12 = out_buf_used (bytes currently in output buffer)
;   r13 = processed_any flag (0=no file/stdin processed yet)
;   ebp = had_error flag (0=ok, 1=error occurred)
;
; Build (modular):
;   nasm -f elf64 -I include/ tools/fnl.asm -o build/tools/fnl.o
;   nasm -f elf64 -I include/ lib/io.asm -o build/lib/io.o
;   ld --gc-sections -n build/tools/fnl.o build/lib/io.o -o fnl

%include "include/linux.inc"
%include "include/macros.inc"

default rel

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close

; ─── Constants ───────────────────────────────────────────
%define READ_BUF_SIZE   262144
%define OUT_BUF_SIZE    524288
%define LINE_BUF_SIZE   1048576
%define FLUSH_THRESHOLD 393216
%define MAX_SEP_LEN     256
%define MAX_FILES       256

; Numbering styles
%define STYLE_ALL       0       ; -b a / -h a / -f a
%define STYLE_NONEMPTY  1       ; -b t (default for body)
%define STYLE_NONE      2       ; -b n / -h n / -f n

; Number formats
%define FMT_RN          0       ; right justified (default)
%define FMT_LN          1       ; left justified
%define FMT_RZ          2       ; right justified zero-padded

; Sections
%define SECTION_HEADER  0
%define SECTION_BODY    1
%define SECTION_FOOTER  2

; mmap flags
%define MAP_PRIVATE     2
%define MAP_POPULATE    0x08000
%define PROT_READ       1
%define MADV_SEQUENTIAL 2
%define MADV_HUGEPAGE   14
%define SYS_MADVISE     28

global _start

section .text

; ─── Entry Point ─────────────────────────────────────────
_start:
    BLOCK_SIGPIPE

    ; Parse argc/argv from stack
    mov     r14, [rsp]              ; argc
    lea     r15, [rsp + 8]          ; argv[0]

    ; Skip argv[0] (program name)
    dec     r14                     ; argc - 1
    add     r15, 8                  ; &argv[1]

    ; Initialize global state
    xor     ebp, ebp                ; had_error = 0
    xor     r12d, r12d              ; out_buf_used = 0
    xor     r13d, r13d              ; processed_any = 0

    ; Initialize nl state with defaults
    mov     byte [body_style], STYLE_NONEMPTY   ; -b t
    mov     byte [header_style], STYLE_NONE     ; -h n
    mov     byte [footer_style], STYLE_NONE     ; -f n
    mov     byte [num_format], FMT_RN           ; -n rn
    mov     qword [line_incr], 1                ; -i 1
    mov     qword [join_blank], 1               ; -l 1
    mov     byte [no_renumber], 0               ; reset at sections
    mov     qword [start_num], 1                ; -v 1
    mov     qword [num_width], 6                ; -w 6
    ; Default separator: TAB
    mov     byte [separator], 9
    mov     qword [sep_len], 1
    ; Default section delimiter: \:
    mov     byte [delim_char1], '\'
    mov     byte [delim_char2], ':'
    mov     byte [delim_len], 2                 ; 2-char delimiter
    ; Current state
    mov     byte [cur_section], SECTION_BODY
    mov     qword [blank_count], 0
    mov     dword [num_files], 0
    mov     qword [line_buf_used], 0
    mov     byte [prefix_valid], 0
    mov     byte [is_default_opts], 1           ; assume default until proven otherwise

    ; Store argv info in globals for option parsing helpers
    mov     [argv_base], r15        ; &argv[1]
    mov     [argv_count], r14       ; argc - 1

    ; Copy start_num to line_number
    mov     rax, [start_num]
    mov     [line_number], rax

    ; If no args, skip parse loop -> done_files will read stdin
    test    r14, r14
    jz      .done_files

    ; Parse arguments using globals for arg index
    mov     qword [arg_index], 0
    mov     byte [seen_dashdash], 0

.parse_loop:
    mov     rbx, [arg_index]
    cmp     rbx, [argv_count]
    jge     .done_files

    mov     rcx, [argv_base]
    mov     rsi, [rcx + rbx*8]      ; argv[i]

    ; If we've seen --, treat everything as filename
    cmp     byte [seen_dashdash], 0
    jne     .is_file

    ; Check for '-' prefix
    cmp     byte [rsi], '-'
    jne     .is_file
    cmp     byte [rsi+1], 0
    je      .is_stdin               ; bare "-" = stdin
    cmp     byte [rsi+1], '-'
    jne     .short_opt

    ; Starts with "--"
    cmp     byte [rsi+2], 0
    je      .set_dashdash           ; exactly "--"

    ; Check --help
    lea     rdi, [rel str_help_flag]
    call    strcmp
    test    eax, eax
    jz      .do_help

    ; Check --version
    mov     rbx, [arg_index]
    mov     rcx, [argv_base]
    mov     rsi, [rcx + rbx*8]
    lea     rdi, [rel str_version_flag]
    call    strcmp
    test    eax, eax
    jz      .do_version

    ; Check long options with =
    mov     rbx, [arg_index]
    mov     rcx, [argv_base]
    mov     rsi, [rcx + rbx*8]
    call    parse_long_option
    test    eax, eax
    jz      .parse_next             ; 0 = success
    ; Error: unrecognized option
    mov     rbx, [arg_index]
    mov     rcx, [argv_base]
    mov     rsi, [rcx + rbx*8]
    call    err_unrecognized_option
    mov     ebp, 1
    movzx   rdi, bpl
    mov     rax, SYS_EXIT
    syscall

.short_opt:
    ; Parse short option cluster starting at rsi+1
    inc     rsi                     ; skip the '-'
    call    parse_short_options
    test    eax, eax
    jnz     .short_opt_error
    jmp     .parse_next

.short_opt_error:
    ; eax < 0 means invalid option
    mov     rbx, [arg_index]
    mov     rcx, [argv_base]
    mov     rsi, [rcx + rbx*8]
    call    err_invalid_option
    mov     ebp, 1
    movzx   rdi, bpl
    mov     rax, SYS_EXIT
    syscall

.set_dashdash:
    mov     byte [seen_dashdash], 1
    jmp     .parse_next

.is_stdin:
    mov     r13d, 1                 ; mark as processed
    mov     edi, STDIN
    call    process_fd
    jmp     .parse_next

.is_file:
    mov     r13d, 1                 ; mark as processed
    mov     rbx, [arg_index]
    mov     rcx, [argv_base]
    mov     rsi, [rcx + rbx*8]
    call    open_and_process
    jmp     .parse_next

.parse_next:
    inc     qword [arg_index]
    jmp     .parse_loop

.done_files:
    ; If no files/stdin were processed, read stdin
    test    r13, r13
    jnz     .final_flush
    mov     edi, STDIN
    call    process_fd

.final_flush:
    ; Handle remaining line in line_buf (no trailing newline)
    cmp     qword [line_buf_used], 0
    je      .no_remaining_line
    call    process_last_line

.no_remaining_line:
    ; Flush remaining output buffer
    call    flush_output
    test    eax, eax
    jnz     .write_error_exit

    ; Exit with appropriate code
    movzx   rdi, bpl
    mov     rax, SYS_EXIT
    syscall

.write_error_exit:
    lea     rdi, [rel str_write_error]
    call    print_error_simple
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

; ─── Help ────────────────────────────────────────────────
.do_help:
    call    flush_output
    mov     rdi, STDOUT
    lea     rsi, [rel help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

; ─── Version ─────────────────────────────────────────────
.do_version:
    call    flush_output
    mov     rdi, STDOUT
    lea     rsi, [rel version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

; ═══════════════════════════════════════════════════════════
; parse_short_options(rsi=ptr to first option char after '-')
; Returns eax=0 on success, eax=-1 on error (invalid option)
; May advance rbx (arg index) to consume option arguments
; ═══════════════════════════════════════════════════════════
parse_short_options:
    push    rbx
    push    r14
    push    r15
    mov     r14, rsi                ; save option string pointer

.pso_loop:
    movzx   eax, byte [r14]
    test    al, al
    jz      .pso_done

    cmp     al, 'b'
    je      .pso_b
    cmp     al, 'd'
    je      .pso_d
    cmp     al, 'f'
    je      .pso_f
    cmp     al, 'h'
    je      .pso_h
    cmp     al, 'i'
    je      .pso_i
    cmp     al, 'l'
    je      .pso_l
    cmp     al, 'n'
    je      .pso_n
    cmp     al, 'p'
    je      .pso_p
    cmp     al, 's'
    je      .pso_s
    cmp     al, 'v'
    je      .pso_v
    cmp     al, 'w'
    je      .pso_w

    ; Unknown option
    mov     eax, -1
    pop     r15
    pop     r14
    pop     rbx
    ret

.pso_p:
    mov     byte [no_renumber], 1
    mov     byte [is_default_opts], 0
    inc     r14
    jmp     .pso_loop

; Options that take a value: try rest of string, else next argv
.pso_b:
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_b_have_val
    ; Next argv
    call    .get_next_arg
    test    rax, rax
    jz      .pso_missing_arg
    mov     r14, rax
.pso_b_have_val:
    mov     rdi, r14
    call    parse_style
    test    eax, eax
    js      .pso_invalid_style
    mov     [body_style], al
    ; Check if still default (body_style=STYLE_NONEMPTY)
    cmp     al, STYLE_NONEMPTY
    je      .pso_consumed
    mov     byte [is_default_opts], 0
    jmp     .pso_consumed

.pso_f:
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_f_have_val
    call    .get_next_arg
    test    rax, rax
    jz      .pso_missing_arg
    mov     r14, rax
.pso_f_have_val:
    mov     rdi, r14
    call    parse_style
    test    eax, eax
    js      .pso_invalid_style
    mov     [footer_style], al
    ; footer style NONE is default
    cmp     al, STYLE_NONE
    je      .pso_consumed
    mov     byte [is_default_opts], 0
    jmp     .pso_consumed

.pso_h:
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_h_have_val
    call    .get_next_arg
    test    rax, rax
    jz      .pso_missing_arg
    mov     r14, rax
.pso_h_have_val:
    mov     rdi, r14
    call    parse_style
    test    eax, eax
    js      .pso_invalid_style
    mov     [header_style], al
    ; header style NONE is default
    cmp     al, STYLE_NONE
    je      .pso_consumed
    mov     byte [is_default_opts], 0
    jmp     .pso_consumed

.pso_d:
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_d_have_val
    call    .get_next_arg
    test    rax, rax
    jz      .pso_missing_arg
    mov     r14, rax
.pso_d_have_val:
    ; Parse delimiter: 1 or 2 chars
    movzx   eax, byte [r14]
    test    al, al
    jz      .pso_d_empty
    mov     [delim_char1], al
    movzx   eax, byte [r14 + 1]
    test    al, al
    jz      .pso_d_one_char
    mov     [delim_char2], al
    mov     byte [delim_len], 2
    ; Check if still default (\:)
    cmp     byte [delim_char1], '\'
    jne     .pso_d_non_default
    cmp     byte [delim_char2], ':'
    je      .pso_consumed
.pso_d_non_default:
    mov     byte [is_default_opts], 0
    jmp     .pso_consumed
.pso_d_one_char:
    mov     byte [delim_char2], ':'  ; implicit ':'
    mov     byte [delim_len], 2
    mov     byte [is_default_opts], 0
    jmp     .pso_consumed
.pso_d_empty:
    ; Empty delimiter disables section matching
    mov     byte [delim_len], 0
    mov     byte [is_default_opts], 0
    jmp     .pso_consumed

.pso_n:
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_n_have_val
    call    .get_next_arg
    test    rax, rax
    jz      .pso_missing_arg
    mov     r14, rax
.pso_n_have_val:
    mov     rdi, r14
    call    parse_format
    test    eax, eax
    js      .pso_invalid_format
    mov     [num_format], al
    cmp     al, FMT_RN
    je      .pso_consumed
    mov     byte [is_default_opts], 0
    jmp     .pso_consumed

.pso_i:
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_i_have_val
    call    .get_next_arg
    test    rax, rax
    jz      .pso_missing_arg
    mov     r14, rax
.pso_i_have_val:
    mov     rdi, r14
    call    parse_number
    test    rdx, rdx
    jnz     .pso_invalid_number
    mov     [line_incr], rax
    cmp     rax, 1
    je      .pso_consumed
    mov     byte [is_default_opts], 0
    jmp     .pso_consumed

.pso_l:
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_l_have_val
    call    .get_next_arg
    test    rax, rax
    jz      .pso_missing_arg
    mov     r14, rax
.pso_l_have_val:
    mov     rdi, r14
    call    parse_number
    test    rdx, rdx
    jnz     .pso_invalid_number
    mov     [join_blank], rax
    cmp     rax, 1
    je      .pso_consumed
    mov     byte [is_default_opts], 0
    jmp     .pso_consumed

.pso_v:
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_v_have_val
    call    .get_next_arg
    test    rax, rax
    jz      .pso_missing_arg
    mov     r14, rax
.pso_v_have_val:
    mov     rdi, r14
    call    parse_signed_number
    test    rdx, rdx
    jnz     .pso_invalid_number
    mov     [start_num], rax
    mov     [line_number], rax
    cmp     rax, 1
    je      .pso_consumed
    mov     byte [is_default_opts], 0
    jmp     .pso_consumed

.pso_w:
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_w_have_val
    call    .get_next_arg
    test    rax, rax
    jz      .pso_missing_arg
    mov     r14, rax
.pso_w_have_val:
    mov     rdi, r14
    call    parse_number
    test    rdx, rdx
    jnz     .pso_invalid_number
    mov     [num_width], rax
    cmp     rax, 6
    je      .pso_consumed
    mov     byte [is_default_opts], 0
    jmp     .pso_consumed

.pso_s:
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_s_have_val
    call    .get_next_arg
    test    rax, rax
    jz      .pso_missing_arg
    mov     r14, rax
.pso_s_have_val:
    ; Copy separator string
    mov     rdi, r14
    call    strlen
    cmp     rax, MAX_SEP_LEN
    jge     .pso_s_too_long
    mov     [sep_len], rax
    ; Copy bytes
    mov     rsi, r14
    lea     rdi, [rel separator]
    mov     rcx, rax
    rep     movsb
    ; Check if still default (single tab)
    cmp     qword [sep_len], 1
    jne     .pso_s_non_default
    cmp     byte [separator], 9
    je      .pso_consumed
.pso_s_non_default:
    mov     byte [is_default_opts], 0
    jmp     .pso_consumed

.pso_s_too_long:
    mov     rax, MAX_SEP_LEN
    mov     [sep_len], rax
    mov     rsi, r14
    lea     rdi, [rel separator]
    mov     rcx, MAX_SEP_LEN
    rep     movsb
    mov     byte [is_default_opts], 0
    jmp     .pso_consumed

.pso_consumed:
    ; The value was consumed — done with this arg
.pso_done:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     rbx
    ret

.pso_missing_arg:
    ; Print "nl: option requires an argument -- 'X'"
    ; The option letter is at [r14 - 1]
    lea     rdi, [rel str_prefix]
    mov     rsi, str_prefix_len
    call    write_stderr
    lea     rdi, [rel str_opt_requires_arg]
    mov     rsi, str_opt_requires_arg_len
    call    write_stderr
    lea     rdi, [r14 - 1]
    mov     rsi, 1
    call    write_stderr
    lea     rdi, [rel str_quote_nl]
    mov     rsi, 2
    call    write_stderr
    lea     rdi, [rel str_try_help]
    mov     rsi, str_try_help_len
    call    write_stderr
    mov     ebp, 1
    movzx   rdi, bpl
    mov     rax, SYS_EXIT
    syscall

.pso_invalid_style:
    ; Print error about invalid style
    lea     rdi, [rel str_prefix]
    mov     rsi, str_prefix_len
    call    write_stderr
    lea     rdi, [rel str_invalid_style]
    mov     rsi, str_invalid_style_len
    call    write_stderr
    mov     rdi, r14
    call    strlen
    mov     rsi, rax
    mov     rdi, r14
    call    write_stderr
    lea     rdi, [rel str_quote_nl]
    mov     rsi, 2
    call    write_stderr
    lea     rdi, [rel str_try_help]
    mov     rsi, str_try_help_len
    call    write_stderr
    mov     ebp, 1
    movzx   rdi, bpl
    mov     rax, SYS_EXIT
    syscall

.pso_invalid_format:
    lea     rdi, [rel str_prefix]
    mov     rsi, str_prefix_len
    call    write_stderr
    lea     rdi, [rel str_invalid_format]
    mov     rsi, str_invalid_format_len
    call    write_stderr
    mov     rdi, r14
    call    strlen
    mov     rsi, rax
    mov     rdi, r14
    call    write_stderr
    lea     rdi, [rel str_quote_nl]
    mov     rsi, 2
    call    write_stderr
    lea     rdi, [rel str_try_help]
    mov     rsi, str_try_help_len
    call    write_stderr
    mov     ebp, 1
    movzx   rdi, bpl
    mov     rax, SYS_EXIT
    syscall

.pso_invalid_number:
    lea     rdi, [rel str_prefix]
    mov     rsi, str_prefix_len
    call    write_stderr
    lea     rdi, [rel str_invalid_number]
    mov     rsi, str_invalid_number_len
    call    write_stderr
    mov     rdi, r14
    call    strlen
    mov     rsi, rax
    mov     rdi, r14
    call    write_stderr
    lea     rdi, [rel str_quote_nl]
    mov     rsi, 2
    call    write_stderr
    lea     rdi, [rel str_try_help]
    mov     rsi, str_try_help_len
    call    write_stderr
    mov     ebp, 1
    movzx   rdi, bpl
    mov     rax, SYS_EXIT
    syscall

; Helper: get next argv element, advance global arg_index
; Returns rax=pointer or 0 if none
.get_next_arg:
    mov     rax, [arg_index]
    inc     rax
    cmp     rax, [argv_count]
    jge     .gna_none
    mov     [arg_index], rax        ; advance global index
    mov     rcx, [argv_base]
    mov     rax, [rcx + rax*8]
    ret
.gna_none:
    xor     eax, eax
    ret

; ═══════════════════════════════════════════════════════════
; parse_long_option(rsi=full option string starting with --)
; Returns eax=0 on success, eax=-1 on unrecognized
; ═══════════════════════════════════════════════════════════
parse_long_option:
    push    rbx
    push    r14
    push    r15
    mov     r14, rsi                ; save full string

    ; Skip "--"
    add     rsi, 2

    ; Try each long option
    ; --body-numbering=STYLE or --body-numbering STYLE
    lea     rdi, [rel str_lo_body]
    call    match_long_opt          ; returns rax=value_ptr or 0
    test    rax, rax
    jnz     .plo_body

    mov     rsi, r14
    add     rsi, 2
    lea     rdi, [rel str_lo_footer]
    call    match_long_opt
    test    rax, rax
    jnz     .plo_footer

    mov     rsi, r14
    add     rsi, 2
    lea     rdi, [rel str_lo_header]
    call    match_long_opt
    test    rax, rax
    jnz     .plo_header

    mov     rsi, r14
    add     rsi, 2
    lea     rdi, [rel str_lo_delim]
    call    match_long_opt
    test    rax, rax
    jnz     .plo_delim

    mov     rsi, r14
    add     rsi, 2
    lea     rdi, [rel str_lo_incr]
    call    match_long_opt
    test    rax, rax
    jnz     .plo_incr

    mov     rsi, r14
    add     rsi, 2
    lea     rdi, [rel str_lo_join]
    call    match_long_opt
    test    rax, rax
    jnz     .plo_join

    mov     rsi, r14
    add     rsi, 2
    lea     rdi, [rel str_lo_numfmt]
    call    match_long_opt
    test    rax, rax
    jnz     .plo_numfmt

    mov     rsi, r14
    add     rsi, 2
    lea     rdi, [rel str_lo_norenumber]
    call    match_long_opt_flag
    test    eax, eax
    jz      .plo_norenumber

    mov     rsi, r14
    add     rsi, 2
    lea     rdi, [rel str_lo_sep]
    call    match_long_opt
    test    rax, rax
    jnz     .plo_sep

    mov     rsi, r14
    add     rsi, 2
    lea     rdi, [rel str_lo_startnum]
    call    match_long_opt
    test    rax, rax
    jnz     .plo_startnum

    mov     rsi, r14
    add     rsi, 2
    lea     rdi, [rel str_lo_width]
    call    match_long_opt
    test    rax, rax
    jnz     .plo_width

    ; Unrecognized
    mov     eax, -1
    pop     r15
    pop     r14
    pop     rbx
    ret

.plo_body:
    mov     rdi, rax
    call    parse_style
    test    eax, eax
    js      .plo_invalid_style
    mov     [body_style], al
    cmp     al, STYLE_NONEMPTY
    je      .plo_ok
    mov     byte [is_default_opts], 0
    jmp     .plo_ok

.plo_footer:
    mov     rdi, rax
    call    parse_style
    test    eax, eax
    js      .plo_invalid_style
    mov     [footer_style], al
    cmp     al, STYLE_NONE
    je      .plo_ok
    mov     byte [is_default_opts], 0
    jmp     .plo_ok

.plo_header:
    mov     rdi, rax
    call    parse_style
    test    eax, eax
    js      .plo_invalid_style
    mov     [header_style], al
    cmp     al, STYLE_NONE
    je      .plo_ok
    mov     byte [is_default_opts], 0
    jmp     .plo_ok

.plo_delim:
    mov     r14, rax
    movzx   eax, byte [r14]
    test    al, al
    jz      .plo_d_empty
    mov     [delim_char1], al
    movzx   eax, byte [r14 + 1]
    test    al, al
    jz      .plo_d_one
    mov     [delim_char2], al
    mov     byte [delim_len], 2
    mov     byte [is_default_opts], 0
    jmp     .plo_ok
.plo_d_one:
    mov     byte [delim_char2], ':'
    mov     byte [delim_len], 2
    mov     byte [is_default_opts], 0
    jmp     .plo_ok
.plo_d_empty:
    mov     byte [delim_len], 0
    mov     byte [is_default_opts], 0
    jmp     .plo_ok

.plo_incr:
    mov     rdi, rax
    call    parse_number
    test    rdx, rdx
    jnz     .plo_invalid_num
    mov     [line_incr], rax
    cmp     rax, 1
    je      .plo_ok
    mov     byte [is_default_opts], 0
    jmp     .plo_ok

.plo_join:
    mov     rdi, rax
    call    parse_number
    test    rdx, rdx
    jnz     .plo_invalid_num
    mov     [join_blank], rax
    cmp     rax, 1
    je      .plo_ok
    mov     byte [is_default_opts], 0
    jmp     .plo_ok

.plo_numfmt:
    mov     rdi, rax
    call    parse_format
    test    eax, eax
    js      .plo_invalid_fmt
    mov     [num_format], al
    cmp     al, FMT_RN
    je      .plo_ok
    mov     byte [is_default_opts], 0
    jmp     .plo_ok

.plo_norenumber:
    mov     byte [no_renumber], 1
    mov     byte [is_default_opts], 0
    jmp     .plo_ok

.plo_sep:
    mov     r14, rax
    mov     rdi, rax
    call    strlen
    cmp     rax, MAX_SEP_LEN
    jge     .plo_sep_trunc
    mov     [sep_len], rax
    mov     rsi, r14
    lea     rdi, [rel separator]
    mov     rcx, rax
    rep     movsb
    mov     byte [is_default_opts], 0
    jmp     .plo_ok
.plo_sep_trunc:
    mov     qword [sep_len], MAX_SEP_LEN
    mov     rsi, r14
    lea     rdi, [rel separator]
    mov     rcx, MAX_SEP_LEN
    rep     movsb
    mov     byte [is_default_opts], 0
    jmp     .plo_ok

.plo_startnum:
    mov     rdi, rax
    call    parse_signed_number
    test    rdx, rdx
    jnz     .plo_invalid_num
    mov     [start_num], rax
    mov     [line_number], rax
    cmp     rax, 1
    je      .plo_ok
    mov     byte [is_default_opts], 0
    jmp     .plo_ok

.plo_width:
    mov     rdi, rax
    call    parse_number
    test    rdx, rdx
    jnz     .plo_invalid_num
    mov     [num_width], rax
    cmp     rax, 6
    je      .plo_ok
    mov     byte [is_default_opts], 0
    jmp     .plo_ok

.plo_ok:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     rbx
    ret

.plo_invalid_style:
    ; Fall through to error exit — handled by caller
    mov     eax, -1
    pop     r15
    pop     r14
    pop     rbx
    ret

.plo_invalid_fmt:
    mov     eax, -1
    pop     r15
    pop     r14
    pop     rbx
    ret

.plo_invalid_num:
    mov     eax, -1
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; match_long_opt(rdi=option_name, rsi=arg after --)
; e.g. rdi="body-numbering", rsi="body-numbering=a"
; Returns rax=pointer to value, or 0 if no match
; Handles both --opt=val and --opt val (next arg)
; ═══════════════════════════════════════════════════════════
match_long_opt:
    push    rbx
    push    r14
    mov     rbx, rdi                ; option name
    mov     r14, rsi                ; arg text

.mlo_cmp:
    movzx   eax, byte [rbx]
    movzx   ecx, byte [r14]
    test    al, al
    jz      .mlo_name_end
    cmp     al, cl
    jne     .mlo_no_match
    inc     rbx
    inc     r14
    jmp     .mlo_cmp

.mlo_name_end:
    ; Option name matched. Check what follows in arg.
    movzx   eax, byte [r14]
    cmp     al, '='
    je      .mlo_eq_val
    test    al, al
    jz      .mlo_next_arg
    ; Extra chars = no match
    jmp     .mlo_no_match

.mlo_eq_val:
    ; Value follows '='
    inc     r14
    mov     rax, r14
    pop     r14
    pop     rbx
    ret

.mlo_next_arg:
    ; Value is in next argv element — use global arg_index
    mov     rax, [arg_index]
    inc     rax
    cmp     rax, [argv_count]
    jge     .mlo_no_match
    mov     [arg_index], rax
    mov     rcx, [argv_base]
    mov     rax, [rcx + rax*8]
    pop     r14
    pop     rbx
    ret

.mlo_no_match:
    xor     eax, eax
    pop     r14
    pop     rbx
    ret

; match_long_opt_flag(rdi=option_name, rsi=arg after --)
; For flags without values (like --no-renumber)
; Returns eax=0 if match, eax=-1 if no match
match_long_opt_flag:
.mlof_cmp:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    test    al, al
    jz      .mlof_name_end
    cmp     al, cl
    jne     .mlof_no
    inc     rdi
    inc     rsi
    jmp     .mlof_cmp
.mlof_name_end:
    cmp     byte [rsi], 0
    jne     .mlof_no
    xor     eax, eax
    ret
.mlof_no:
    mov     eax, -1
    ret

; ═══════════════════════════════════════════════════════════
; parse_style(rdi=string) -> eax=style or eax=-1 on error
; ═══════════════════════════════════════════════════════════
parse_style:
    movzx   eax, byte [rdi]
    cmp     al, 'a'
    je      .ps_all
    cmp     al, 't'
    je      .ps_nonempty
    cmp     al, 'n'
    je      .ps_none
    cmp     al, 'p'
    je      .ps_regex
    mov     eax, -1
    ret
.ps_all:
    cmp     byte [rdi+1], 0
    jne     .ps_err
    mov     eax, STYLE_ALL
    ret
.ps_nonempty:
    cmp     byte [rdi+1], 0
    jne     .ps_err
    mov     eax, STYLE_NONEMPTY
    ret
.ps_none:
    cmp     byte [rdi+1], 0
    jne     .ps_err
    mov     eax, STYLE_NONE
    ret
.ps_regex:
    ; pBRE — skip regex, treat as 'none' (documented limitation)
    mov     eax, STYLE_NONE
    ret
.ps_err:
    mov     eax, -1
    ret

; ═══════════════════════════════════════════════════════════
; parse_format(rdi=string) -> eax=format or eax=-1
; ═══════════════════════════════════════════════════════════
parse_format:
    movzx   eax, byte [rdi]
    cmp     al, 'l'
    je      .pf_ln
    cmp     al, 'r'
    je      .pf_rn_or_rz
    mov     eax, -1
    ret
.pf_ln:
    cmp     byte [rdi+1], 'n'
    jne     .pf_err
    cmp     byte [rdi+2], 0
    jne     .pf_err
    mov     eax, FMT_LN
    ret
.pf_rn_or_rz:
    movzx   eax, byte [rdi+1]
    cmp     al, 'n'
    je      .pf_rn
    cmp     al, 'z'
    je      .pf_rz
    jmp     .pf_err
.pf_rn:
    cmp     byte [rdi+2], 0
    jne     .pf_err
    mov     eax, FMT_RN
    ret
.pf_rz:
    cmp     byte [rdi+2], 0
    jne     .pf_err
    mov     eax, FMT_RZ
    ret
.pf_err:
    mov     eax, -1
    ret

; ═══════════════════════════════════════════════════════════
; parse_number(rdi=string) -> rax=value, rdx=0 on success, rdx=1 on error
; ═══════════════════════════════════════════════════════════
parse_number:
    xor     rax, rax
    xor     rdx, rdx
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .pn_err                 ; empty string
.pn_loop:
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .pn_done
    sub     cl, '0'
    cmp     cl, 9
    ja      .pn_err
    imul    rax, 10
    movzx   ecx, byte [rdi]
    sub     cl, '0'
    add     rax, rcx
    inc     rdi
    jmp     .pn_loop
.pn_done:
    xor     edx, edx
    ret
.pn_err:
    mov     edx, 1
    ret

; ═══════════════════════════════════════════════════════════
; parse_signed_number(rdi=string) -> rax=value, rdx=0 on success, rdx=1 on error
; ═══════════════════════════════════════════════════════════
parse_signed_number:
    xor     r8d, r8d                ; negative flag
    movzx   eax, byte [rdi]
    cmp     al, '-'
    jne     .psn_pos
    mov     r8d, 1
    inc     rdi
.psn_pos:
    call    parse_number
    test    rdx, rdx
    jnz     .psn_ret
    test    r8d, r8d
    jz      .psn_ret
    neg     rax
.psn_ret:
    ret

; ═══════════════════════════════════════════════════════════
; open_and_process(rsi=filename) — Opens file, tries mmap, falls back to read
; ═══════════════════════════════════════════════════════════
open_and_process:
    push    rbx
    push    r14
    push    r15
    mov     rbx, rsi                ; save filename

    ; Open file
    mov     rdi, rsi
    xor     esi, esi                ; O_RDONLY
    xor     edx, edx                ; mode = 0
    mov     rax, SYS_OPEN
    syscall

    test    rax, rax
    js      .oap_open_error

    mov     r14d, eax               ; save fd

    ; fstat to get file size
    sub     rsp, 144                ; struct stat
    mov     rdi, r14
    mov     rsi, rsp
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .oap_fstat_fail

    ; File size is at offset 48 in struct stat
    mov     r15, [rsp + 48]         ; st_size

    ; Check if it's a regular file with size > 0
    mov     eax, [rsp + 24]         ; st_mode (at offset 24)
    and     eax, 0xF000             ; S_IFMT mask
    cmp     eax, 0x8000             ; S_IFREG
    jne     .oap_use_read

    test    r15, r15
    jz      .oap_empty_file         ; empty file, nothing to do

    ; mmap the file with MAP_POPULATE for prefaulting
    xor     edi, edi                ; addr = NULL
    mov     rsi, r15                ; length = file_size
    mov     edx, PROT_READ          ; PROT_READ
    mov     r10d, MAP_PRIVATE | MAP_POPULATE  ; MAP_PRIVATE | MAP_POPULATE
    mov     r8, r14                 ; fd
    xor     r9d, r9d                ; offset = 0
    mov     rax, SYS_MMAP
    syscall

    ; Check for mmap failure
    cmp     rax, -4096
    ja      .oap_use_read           ; mmap failed, fall back to read

    ; mmap succeeded — process the mapped data directly
    add     rsp, 144                ; clean up stat buffer
    push    rax                     ; save mmap address
    push    r15                     ; save file size

    ; madvise SEQUENTIAL for readahead
    mov     rdi, rax
    mov     rsi, r15
    mov     edx, MADV_SEQUENTIAL
    mov     rax, SYS_MADVISE
    syscall

    ; madvise HUGEPAGE to use transparent huge pages
    mov     rdi, [rsp + 8]         ; mmap address
    mov     rsi, [rsp]             ; file size
    mov     edx, MADV_HUGEPAGE
    mov     rax, SYS_MADVISE
    syscall

    ; Restore mmap address from stack (madvise clobbered rdi)
    mov     rax, [rsp + 8]          ; mmap address is at rsp+8 after push rax; push r15

    ; Process the entire mmap'd buffer
    mov     [mmap_base], rax
    mov     [mmap_size], r15

    ; Check if we can use fast path
    cmp     byte [is_default_opts], 1
    jne     .oap_slow_mmap
    call    process_mmap_fast
    jmp     .oap_mmap_done

.oap_slow_mmap:
    call    process_mmap

.oap_mmap_done:
    ; munmap
    pop     r15
    pop     rax
    mov     rdi, rax
    mov     rsi, r15
    mov     rax, SYS_MUNMAP
    syscall

    ; Close file
    mov     edi, r14d
    mov     rax, SYS_CLOSE
    syscall

    pop     r15
    pop     r14
    pop     rbx
    ret

.oap_fstat_fail:
    add     rsp, 144
.oap_use_read:
    add     rsp, 144
    ; Fall back to streaming read
    mov     edi, r14d
    call    process_fd

    ; Close file
    mov     edi, r14d
    mov     rax, SYS_CLOSE
    syscall

    pop     r15
    pop     r14
    pop     rbx
    ret

.oap_empty_file:
    add     rsp, 144
    ; Close file
    mov     edi, r14d
    mov     rax, SYS_CLOSE
    syscall

    pop     r15
    pop     r14
    pop     rbx
    ret

.oap_open_error:
    neg     rax
    mov     rdi, rbx
    mov     esi, eax
    call    err_file
    mov     ebp, 1
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; process_mmap_fast — Ultra-fast path for default options on mmap'd files
;
; Default: -b t -n rn -w 6 -s '\t' -i 1 -v 1 -d '\:'
; Number non-empty lines, right-justified 6-digit, tab separator.
;   Non-empty: "     1\tLINE_CONTENT\n"
;   Empty:     "       \n" (7 spaces + newline = 8 bytes)
;
; Key optimizations:
;   - Incremental ASCII itoa: keep number as ASCII digits, just inc last byte
;   - r13 = scan pointer (frees rsi for rep movsb, no push/pop needed)
;   - 512KB output buffer with 384KB flush threshold
;   - 64-byte SIMD scan (4x movdqu) for wider search
;   - Threshold-based copy: SIMD 16-byte chunks for short lines, rep movsb for long
;
; Register allocation in hot loop:
;   r13 = scan pointer in mmap'd data (instead of rsi, to free rsi for rep movsb)
;   r8  = end of mmap'd data
;   r12 = out_buf_used (global)
;   r9  = line_number (local)
;   r15 = out_buf base
;   r14 = line start pointer
;   rbp = pointer to num_ascii (7-byte: 6 digits + tab, on stack)
;   rdi = output write pointer (transient)
; ═══════════════════════════════════════════════════════════
process_mmap_fast:
    push    rbx
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r13, [mmap_base]        ; r13 = scan pointer
    mov     r8, r13
    add     r8, [mmap_size]         ; r8 = end of data
    mov     r9, [line_number]       ; r9 = current line number (fast local)
    lea     r15, [rel out_buf]      ; r15 = base of output buffer

    ; Preload SIMD newline pattern
    movdqa  xmm15, [rel newline_pattern]

    ; --- Initialize incremental ASCII number buffer on stack ---
    sub     rsp, 16
    mov     rbp, rsp                ; rbp -> num_ascii[0..6]+tab

    mov     dword [rbp], 0x20202020
    mov     word [rbp+4], 0x2020
    mov     byte [rbp+6], 9         ; tab separator

    mov     rax, r9
    cmp     rax, 999999
    ja      .pmf_init_fallback

    lea     r10, [rbp + 5]
.pmf_init_digit:
    test    rax, rax
    jz      .pmf_init_done
    mov     rcx, rax
    mov     rdx, 0xCCCCCCCCCCCCCCCD
    mul     rdx
    shr     rdx, 3
    lea     r11, [rdx + rdx*4]
    add     r11, r11
    sub     rcx, r11
    add     cl, '0'
    mov     [r10], cl
    dec     r10
    mov     rax, rdx
    jmp     .pmf_init_digit

.pmf_init_done:
    mov     r14, r13                ; line starts at current scan position

    ; ─── Main scan loop ──────────────────────────────────
.pmf_scan_loop:
    ; Proactive flush check (prevents expensive per-line overflow handling)
    cmp     r12, FLUSH_THRESHOLD
    jb      .pmf_no_flush
    push    r8
    push    r9
    push    r13
    push    r14
    call    flush_output
    pop     r14
    pop     r13
    pop     r9
    pop     r8

.pmf_no_flush:
    ; --- SIMD scan: 64 bytes at a time, then 16, then scalar ---
    mov     rax, r8
    sub     rax, r13
    cmp     rax, 64
    jl      .pmf_try_16

    movdqu  xmm0, [r13]
    pcmpeqb xmm0, xmm15
    pmovmskb ecx, xmm0
    test    ecx, ecx
    jnz     .pmf_found_in_0

    movdqu  xmm0, [r13 + 16]
    pcmpeqb xmm0, xmm15
    pmovmskb ecx, xmm0
    test    ecx, ecx
    jnz     .pmf_found_in_1

    movdqu  xmm0, [r13 + 32]
    pcmpeqb xmm0, xmm15
    pmovmskb ecx, xmm0
    test    ecx, ecx
    jnz     .pmf_found_in_2

    movdqu  xmm0, [r13 + 48]
    pcmpeqb xmm0, xmm15
    pmovmskb ecx, xmm0
    test    ecx, ecx
    jnz     .pmf_found_in_3

    add     r13, 64
    jmp     .pmf_scan_loop

.pmf_found_in_3:
    add     r13, 16
.pmf_found_in_2:
    add     r13, 16
.pmf_found_in_1:
    add     r13, 16
.pmf_found_in_0:
    mov     eax, ecx
    jmp     .pmf_nl_loop

.pmf_try_16:
    cmp     rax, 16
    jl      .pmf_scalar_scan

    movdqu  xmm0, [r13]
    pcmpeqb xmm0, xmm15
    pmovmskb eax, xmm0
    test    eax, eax
    jnz     .pmf_nl_loop

    add     r13, 16
    jmp     .pmf_scan_loop

    ; ─── Process newlines in current 16-byte window ──────
.pmf_nl_loop:
    test    eax, eax
    jz      .pmf_nl_loop_done

    tzcnt   ecx, eax               ; ecx = position of first newline (tzcnt faster than bsf)
    btr     eax, ecx

    lea     rdx, [r13 + rcx]       ; rdx = pointer to newline char
    mov     rbx, rdx
    sub     rbx, r14                ; rbx = line length

    test    rbx, rbx
    jz      .pmf_empty_line

    ; --- Section delimiter quick check (lengths 2, 4, 6 only) ---
    cmp     rbx, 6
    ja      .pmf_nonempty_line
    cmp     rbx, 2
    jb      .pmf_nonempty_line
    test    rbx, 1
    jnz     .pmf_nonempty_line
    cmp     byte [r14], '\'
    jne     .pmf_nonempty_line
    cmp     byte [r14+1], ':'
    jne     .pmf_nonempty_line
    cmp     rbx, 2
    je      .pmf_delim_footer
    cmp     byte [r14+2], '\'
    jne     .pmf_nonempty_line
    cmp     byte [r14+3], ':'
    jne     .pmf_nonempty_line
    cmp     rbx, 4
    je      .pmf_delim_body
    cmp     byte [r14+4], '\'
    jne     .pmf_nonempty_line
    cmp     byte [r14+5], ':'
    jne     .pmf_nonempty_line
    mov     byte [cur_section], SECTION_HEADER
    jmp     .pmf_delim_fallback_slow
.pmf_delim_body:
    ; Body section: can stay in fast path (body uses STYLE_NONEMPTY = default)
    mov     byte [cur_section], SECTION_BODY
    push    rax
    push    rdx
    mov     r9, [start_num]
    mov     qword [blank_count], 0
    ; Re-init the ASCII number buffer
    mov     dword [rbp], 0x20202020
    mov     word [rbp+4], 0x2020
    mov     byte [rbp+6], 9
    mov     rax, r9
    cmp     rax, 999999
    ja      .pmf_delim_body_emit
    lea     r10, [rbp + 5]
.pmf_delim_body_reinit:
    test    rax, rax
    jz      .pmf_delim_body_emit
    mov     rcx, rax
    mov     rdx, 0xCCCCCCCCCCCCCCCD
    mul     rdx
    shr     rdx, 3
    lea     r11, [rdx + rdx*4]
    add     r11, r11
    sub     rcx, r11
    add     cl, '0'
    mov     [r10], cl
    dec     r10
    mov     rax, rdx
    jmp     .pmf_delim_body_reinit
.pmf_delim_body_emit:
    lea     rdi, [r15 + r12]
    mov     byte [rdi], 10
    inc     r12
    pop     rdx
    pop     rax
    lea     r14, [rdx + 1]
    jmp     .pmf_nl_loop

.pmf_delim_footer:
    mov     byte [cur_section], SECTION_FOOTER
.pmf_delim_fallback_slow:
    ; Header/Footer use STYLE_NONE — fall back to slow path which handles
    ; section-specific numbering styles correctly.
    ; Emit delimiter newline, then hand off remaining data.
    lea     rdi, [r15 + r12]
    mov     byte [rdi], 10
    inc     r12
    mov     [line_number], r9
    lea     r14, [rdx + 1]          ; data continues after newline
    mov     [mmap_base], r14
    mov     rax, r8
    sub     rax, r14
    mov     [mmap_size], rax
    test    rax, rax
    jle     .pmf_done
    call    process_mmap
    mov     r9, [line_number]       ; reload (slow path may have changed it)
    jmp     .pmf_done

.pmf_nonempty_line:
    ; Ensure enough output space: 7 + rbx + 1 + 16 (safety)
    lea     rdi, [r12 + rbx]
    add     rdi, 24
    cmp     rdi, OUT_BUF_SIZE
    jb      .pmf_ne_have_space
    push    rax
    push    rcx
    push    rdx
    push    rbx
    push    r13
    push    r14
    call    flush_output
    pop     r14
    pop     r13
    pop     rbx
    pop     rdx
    pop     rcx
    pop     rax

.pmf_ne_have_space:
    lea     rdi, [r15 + r12]

    cmp     r9, 999999
    ja      .pmf_big_number

    ; Copy 8 bytes of number+tab from stack (only 7 meaningful)
    mov     r10, [rbp]
    mov     [rdi], r10
    add     rdi, 7

    ; Copy line content from r14 (length rbx) to rdi
    ; Overlapping SIMD technique: for N bytes, load first and last chunks
    ; and write them (overlapping is fine for copies where src != dst)
    ; This minimizes branches for the common case (lines 1-64 bytes)
    mov     rsi, r14                ; source
    mov     rcx, rbx                ; count

    ; Optimized copy with common-case-first ordering
    ; Most lines are 20-60 bytes, so check 17-32 and 33-64 first
    cmp     rcx, 32
    jbe     .pmf_copy_le32
    cmp     rcx, 64
    ja      .pmf_copy_big
    ; 33-64 bytes (most common for avg ~38 byte lines)
    movdqu  xmm0, [rsi]
    movdqu  xmm1, [rsi + 16]
    movdqu  xmm2, [rsi + rcx - 32]
    movdqu  xmm3, [rsi + rcx - 16]
    movdqu  [rdi], xmm0
    movdqu  [rdi + 16], xmm1
    movdqu  [rdi + rcx - 32], xmm2
    movdqu  [rdi + rcx - 16], xmm3
    add     rdi, rcx
    jmp     .pmf_copy_done

.pmf_copy_le32:
    cmp     rcx, 16
    jbe     .pmf_copy_le16
    ; 17-32 bytes: load first 16 + last 16
    movdqu  xmm0, [rsi]
    movdqu  xmm1, [rsi + rcx - 16]
    movdqu  [rdi], xmm0
    movdqu  [rdi + rcx - 16], xmm1
    add     rdi, rcx
    jmp     .pmf_copy_done

.pmf_copy_big:
    ; > 64 bytes: rep movsb (ERMS)
    rep     movsb
    jmp     .pmf_copy_done

.pmf_copy_le16:
    cmp     rcx, 8
    jbe     .pmf_copy_le8
    ; 9-16 bytes
    mov     r10, [rsi]
    mov     r11, [rsi + rcx - 8]
    mov     [rdi], r10
    mov     [rdi + rcx - 8], r11
    add     rdi, rcx
    jmp     .pmf_copy_done

.pmf_copy_le8:
    cmp     rcx, 4
    jbe     .pmf_copy_le4
    ; 5-8 bytes
    mov     r10d, [rsi]
    mov     r11d, [rsi + rcx - 4]
    mov     [rdi], r10d
    mov     [rdi + rcx - 4], r11d
    add     rdi, rcx
    jmp     .pmf_copy_done

.pmf_copy_le4:
    ; 1-4 bytes: load first + overlapping last
    cmp     rcx, 1
    je      .pmf_copy_1
    ; 2-4 bytes
    movzx   r10d, word [rsi]
    movzx   r11d, word [rsi + rcx - 2]
    mov     [rdi], r10w
    mov     [rdi + rcx - 2], r11w
    add     rdi, rcx
    jmp     .pmf_copy_done
.pmf_copy_1:
    mov     r10b, [rsi]
    mov     [rdi], r10b
    inc     rdi

.pmf_copy_done:
    mov     byte [rdi], 10
    inc     rdi
    mov     r12, rdi
    sub     r12, r15

    inc     r9

    ; Incremental ASCII increment
    cmp     byte [rbp + 5], '9'
    jne     .pmf_inc_simple
    jmp     .pmf_inc_carry

.pmf_inc_simple:
    inc     byte [rbp + 5]
    lea     r14, [rdx + 1]
    jmp     .pmf_nl_loop

.pmf_inc_carry:
    mov     byte [rbp + 5], '0'
    cmp     byte [rbp + 4], '9'
    jne     .pmf_carry_pos4
    mov     byte [rbp + 4], '0'
    cmp     byte [rbp + 3], '9'
    jne     .pmf_carry_pos3
    mov     byte [rbp + 3], '0'
    cmp     byte [rbp + 2], '9'
    jne     .pmf_carry_pos2
    mov     byte [rbp + 2], '0'
    cmp     byte [rbp + 1], '9'
    jne     .pmf_carry_pos1
    mov     byte [rbp + 1], '0'
    cmp     byte [rbp + 0], '9'
    jne     .pmf_carry_pos0
    mov     byte [rbp + 0], '0'
    lea     r14, [rdx + 1]
    jmp     .pmf_nl_loop
.pmf_carry_pos0:
    cmp     byte [rbp + 0], ' '
    jne     .pmf_carry_pos0_inc
    mov     byte [rbp + 0], '1'
    lea     r14, [rdx + 1]
    jmp     .pmf_nl_loop
.pmf_carry_pos0_inc:
    inc     byte [rbp + 0]
    lea     r14, [rdx + 1]
    jmp     .pmf_nl_loop
.pmf_carry_pos1:
    cmp     byte [rbp + 1], ' '
    jne     .pmf_carry_pos1_inc
    mov     byte [rbp + 1], '1'
    lea     r14, [rdx + 1]
    jmp     .pmf_nl_loop
.pmf_carry_pos1_inc:
    inc     byte [rbp + 1]
    lea     r14, [rdx + 1]
    jmp     .pmf_nl_loop
.pmf_carry_pos2:
    cmp     byte [rbp + 2], ' '
    jne     .pmf_carry_pos2_inc
    mov     byte [rbp + 2], '1'
    lea     r14, [rdx + 1]
    jmp     .pmf_nl_loop
.pmf_carry_pos2_inc:
    inc     byte [rbp + 2]
    lea     r14, [rdx + 1]
    jmp     .pmf_nl_loop
.pmf_carry_pos3:
    cmp     byte [rbp + 3], ' '
    jne     .pmf_carry_pos3_inc
    mov     byte [rbp + 3], '1'
    lea     r14, [rdx + 1]
    jmp     .pmf_nl_loop
.pmf_carry_pos3_inc:
    inc     byte [rbp + 3]
    lea     r14, [rdx + 1]
    jmp     .pmf_nl_loop
.pmf_carry_pos4:
    cmp     byte [rbp + 4], ' '
    jne     .pmf_carry_pos4_inc
    mov     byte [rbp + 4], '1'
    lea     r14, [rdx + 1]
    jmp     .pmf_nl_loop
.pmf_carry_pos4_inc:
    inc     byte [rbp + 4]
    lea     r14, [rdx + 1]
    jmp     .pmf_nl_loop

.pmf_big_number:
    ; Number > 999999: multiply-by-magic itoa (rare path)
    push    rax
    push    rdx
    push    rbx
    mov     rax, r9
    lea     r10, [rel itoa_buf + 31]
    xor     ecx, ecx
.pmf_big_itoa:
    mov     r11, rax
    mov     rdx, 0xCCCCCCCCCCCCCCCD
    mul     rdx
    shr     rdx, 3
    lea     rbx, [rdx + rdx*4]
    add     rbx, rbx
    sub     r11, rbx
    add     r11b, '0'
    dec     r10
    mov     [r10], r11b
    inc     ecx
    mov     rax, rdx
    test    rax, rax
    jnz     .pmf_big_itoa
    mov     eax, 6
    sub     eax, ecx
    jle     .pmf_big_no_pad
    push    rcx
    mov     ecx, eax
    mov     al, ' '
    rep     stosb
    pop     rcx
.pmf_big_no_pad:
    mov     rsi, r10
    mov     eax, ecx
    mov     ecx, eax
    rep     movsb
    mov     byte [rdi], 9
    inc     rdi
    pop     rbx
    pop     rdx
    pop     rax
    mov     rsi, r14
    mov     rcx, rbx
    rep     movsb
    mov     byte [rdi], 10
    inc     rdi
    mov     r12, rdi
    sub     r12, r15
    inc     r9
    lea     r14, [rdx + 1]
    jmp     .pmf_nl_loop

.pmf_empty_line:
    lea     rdi, [r12 + 8]
    cmp     rdi, OUT_BUF_SIZE
    jb      .pmf_empty_have_space
    push    rax
    push    rcx
    push    rdx
    push    r13
    push    r14
    call    flush_output
    pop     r14
    pop     r13
    pop     rdx
    pop     rcx
    pop     rax
.pmf_empty_have_space:
    lea     rdi, [r15 + r12]
    mov     r10, 0x0A20202020202020
    mov     [rdi], r10
    add     r12, 8
    lea     r14, [rdx + 1]
    jmp     .pmf_nl_loop

.pmf_nl_loop_done:
    add     r13, 16
    jmp     .pmf_scan_loop

    ; ─── Scalar tail: < 16 bytes remain ──────────────────
.pmf_scalar_scan:
    cmp     r13, r8
    jge     .pmf_done

    cmp     byte [r13], 10
    je      .pmf_scalar_nl

    inc     r13
    jmp     .pmf_scalar_scan

.pmf_scalar_nl:
    mov     rbx, r13
    sub     rbx, r14                ; rbx = line length
    mov     rdx, r13                ; rdx = newline pointer

    test    rbx, rbx
    jz      .pmf_scalar_empty

    ; Section delimiter check
    cmp     rbx, 6
    ja      .pmf_scalar_nonempty
    cmp     rbx, 2
    jb      .pmf_scalar_nonempty
    test    rbx, 1
    jnz     .pmf_scalar_nonempty
    cmp     byte [r14], '\'
    jne     .pmf_scalar_nonempty
    cmp     byte [r14+1], ':'
    jne     .pmf_scalar_nonempty
    cmp     rbx, 2
    je      .pmf_sc_delim_footer
    cmp     byte [r14+2], '\'
    jne     .pmf_scalar_nonempty
    cmp     byte [r14+3], ':'
    jne     .pmf_scalar_nonempty
    cmp     rbx, 4
    je      .pmf_sc_delim_body
    cmp     byte [r14+4], '\'
    jne     .pmf_scalar_nonempty
    cmp     byte [r14+5], ':'
    jne     .pmf_scalar_nonempty
    mov     byte [cur_section], SECTION_HEADER
    jmp     .pmf_sc_delim_fallback_slow
.pmf_sc_delim_body:
    ; Body section: stay in fast path
    mov     byte [cur_section], SECTION_BODY
    mov     r9, [start_num]
    mov     qword [blank_count], 0
    mov     dword [rbp], 0x20202020
    mov     word [rbp+4], 0x2020
    mov     byte [rbp+6], 9
    push    rdx
    mov     rax, r9
    lea     r10, [rbp + 5]
.pmf_sc_delim_reinit:
    test    rax, rax
    jz      .pmf_sc_delim_reinit_done
    mov     rcx, rax
    mov     rdx, 0xCCCCCCCCCCCCCCCD
    mul     rdx
    shr     rdx, 3
    lea     r11, [rdx + rdx*4]
    add     r11, r11
    sub     rcx, r11
    add     cl, '0'
    mov     [r10], cl
    dec     r10
    mov     rax, rdx
    jmp     .pmf_sc_delim_reinit
.pmf_sc_delim_reinit_done:
    pop     rdx
    lea     rdi, [r15 + r12]
    mov     byte [rdi], 10
    inc     r12
    lea     r14, [rdx + 1]
    lea     r13, [rdx + 1]
    jmp     .pmf_scalar_scan

.pmf_sc_delim_footer:
    mov     byte [cur_section], SECTION_FOOTER
.pmf_sc_delim_fallback_slow:
    ; Header/Footer: fall back to slow path
    lea     rdi, [r15 + r12]
    mov     byte [rdi], 10
    inc     r12
    mov     [line_number], r9
    lea     r14, [rdx + 1]
    mov     [mmap_base], r14
    mov     rax, r8
    sub     rax, r14
    mov     [mmap_size], rax
    test    rax, rax
    jle     .pmf_done
    call    process_mmap
    mov     r9, [line_number]
    jmp     .pmf_done

.pmf_scalar_nonempty:
    lea     rdi, [r12 + rbx]
    add     rdi, 24
    cmp     rdi, OUT_BUF_SIZE
    jb      .pmf_sc_ne_space
    push    rdx
    push    rbx
    push    r13
    push    r14
    call    flush_output
    pop     r14
    pop     r13
    pop     rbx
    pop     rdx
.pmf_sc_ne_space:
    lea     rdi, [r15 + r12]

    cmp     r9, 999999
    ja      .pmf_sc_big_num

    mov     r10, [rbp]
    mov     [rdi], r10
    add     rdi, 7

    mov     rsi, r14
    mov     rcx, rbx
    rep     movsb

    mov     byte [rdi], 10
    inc     rdi
    mov     r12, rdi
    sub     r12, r15

    inc     r9
    cmp     byte [rbp + 5], '9'
    jne     .pmf_sc_inc_simple
    mov     byte [rbp + 5], '0'
    cmp     byte [rbp + 4], '9'
    jne     .pmf_sc_c4
    mov     byte [rbp + 4], '0'
    cmp     byte [rbp + 3], '9'
    jne     .pmf_sc_c3
    mov     byte [rbp + 3], '0'
    cmp     byte [rbp + 2], '9'
    jne     .pmf_sc_c2
    mov     byte [rbp + 2], '0'
    cmp     byte [rbp + 1], '9'
    jne     .pmf_sc_c1
    mov     byte [rbp + 1], '0'
    cmp     byte [rbp + 0], '9'
    jne     .pmf_sc_c0
    mov     byte [rbp + 0], '0'
    jmp     .pmf_sc_advance
.pmf_sc_c0:
    cmp     byte [rbp + 0], ' '
    jne     .pmf_sc_c0i
    mov     byte [rbp + 0], '1'
    jmp     .pmf_sc_advance
.pmf_sc_c0i:
    inc     byte [rbp + 0]
    jmp     .pmf_sc_advance
.pmf_sc_c1:
    cmp     byte [rbp + 1], ' '
    jne     .pmf_sc_c1i
    mov     byte [rbp + 1], '1'
    jmp     .pmf_sc_advance
.pmf_sc_c1i:
    inc     byte [rbp + 1]
    jmp     .pmf_sc_advance
.pmf_sc_c2:
    cmp     byte [rbp + 2], ' '
    jne     .pmf_sc_c2i
    mov     byte [rbp + 2], '1'
    jmp     .pmf_sc_advance
.pmf_sc_c2i:
    inc     byte [rbp + 2]
    jmp     .pmf_sc_advance
.pmf_sc_c3:
    cmp     byte [rbp + 3], ' '
    jne     .pmf_sc_c3i
    mov     byte [rbp + 3], '1'
    jmp     .pmf_sc_advance
.pmf_sc_c3i:
    inc     byte [rbp + 3]
    jmp     .pmf_sc_advance
.pmf_sc_c4:
    cmp     byte [rbp + 4], ' '
    jne     .pmf_sc_c4i
    mov     byte [rbp + 4], '1'
    jmp     .pmf_sc_advance
.pmf_sc_c4i:
    inc     byte [rbp + 4]
    jmp     .pmf_sc_advance

.pmf_sc_inc_simple:
    inc     byte [rbp + 5]

.pmf_sc_advance:
    lea     r14, [rdx + 1]
    lea     r13, [rdx + 1]
    jmp     .pmf_scalar_scan

.pmf_sc_big_num:
    push    rax
    push    rdx
    push    rbx
    mov     rax, r9
    lea     r10, [rel itoa_buf + 31]
    xor     ecx, ecx
.pmf_sc_big_itoa:
    mov     r11, rax
    mov     rdx, 0xCCCCCCCCCCCCCCCD
    mul     rdx
    shr     rdx, 3
    lea     rbx, [rdx + rdx*4]
    add     rbx, rbx
    sub     r11, rbx
    add     r11b, '0'
    dec     r10
    mov     [r10], r11b
    inc     ecx
    mov     rax, rdx
    test    rax, rax
    jnz     .pmf_sc_big_itoa
    mov     eax, 6
    sub     eax, ecx
    jle     .pmf_sc_big_no_pad
    push    rcx
    mov     ecx, eax
    mov     al, ' '
    rep     stosb
    pop     rcx
.pmf_sc_big_no_pad:
    mov     rsi, r10
    mov     eax, ecx
    mov     ecx, eax
    rep     movsb
    mov     byte [rdi], 9
    inc     rdi
    pop     rbx
    pop     rdx
    pop     rax
    mov     rsi, r14
    mov     rcx, rbx
    rep     movsb
    mov     byte [rdi], 10
    inc     rdi
    mov     r12, rdi
    sub     r12, r15
    inc     r9
    lea     r14, [rdx + 1]
    lea     r13, [rdx + 1]
    jmp     .pmf_scalar_scan

.pmf_scalar_empty:
    lea     rdi, [r12 + 8]
    cmp     rdi, OUT_BUF_SIZE
    jb      .pmf_sc_empty_space
    push    rdx
    push    r13
    push    r14
    call    flush_output
    pop     r14
    pop     r13
    pop     rdx
.pmf_sc_empty_space:
    lea     rdi, [r15 + r12]
    mov     r10, 0x0A20202020202020
    mov     [rdi], r10
    add     r12, 8
    lea     r14, [r13 + 1]
    inc     r13
    jmp     .pmf_scalar_scan

.pmf_init_fallback:
    add     rsp, 16
    mov     [line_number], r9
    call    process_mmap
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

.pmf_done:
    ; Handle remaining data without trailing newline (e.g., "hello" with no \n)
    mov     [line_number], r9
    cmp     r14, r8
    jge     .pmf_exit
    ; There's trailing data at [r14..r8) without a newline
    mov     [line_ptr], r14
    mov     rax, r8
    sub     rax, r14
    mov     [line_len], rax
    call    process_line_direct
    ; Advance line number (process_line_direct updates [line_number])

.pmf_exit:
    add     rsp, 16
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; check_section_delimiter_direct_inline — lightweight delimiter check
; Uses [line_ptr]/[line_len] already set
; Returns eax = SECTION_HEADER(0), SECTION_BODY(1), SECTION_FOOTER(2), or -1
; ═══════════════════════════════════════════════════════════
check_section_delimiter_direct_inline:
    mov     rsi, [line_ptr]
    mov     rcx, [line_len]

    ; Default delimiter is \: (backslash + colon)
    ; Header: \:\:\: (6 bytes), Body: \:\: (4 bytes), Footer: \: (2 bytes)
    movzx   eax, byte [delim_char1]
    movzx   edx, byte [delim_char2]

    cmp     rcx, 6
    je      .csdi_check_header
    cmp     rcx, 4
    je      .csdi_check_body
    cmp     rcx, 2
    je      .csdi_check_footer
    mov     eax, -1
    ret

.csdi_check_header:
    cmp     [rsi], al
    jne     .csdi_no
    cmp     [rsi+1], dl
    jne     .csdi_no
    cmp     [rsi+2], al
    jne     .csdi_no
    cmp     [rsi+3], dl
    jne     .csdi_no
    cmp     [rsi+4], al
    jne     .csdi_no
    cmp     [rsi+5], dl
    jne     .csdi_no
    mov     eax, SECTION_HEADER
    ret

.csdi_check_body:
    cmp     [rsi], al
    jne     .csdi_no
    cmp     [rsi+1], dl
    jne     .csdi_no
    cmp     [rsi+2], al
    jne     .csdi_no
    cmp     [rsi+3], dl
    jne     .csdi_no
    mov     eax, SECTION_BODY
    ret

.csdi_check_footer:
    cmp     [rsi], al
    jne     .csdi_no
    cmp     [rsi+1], dl
    jne     .csdi_no
    mov     eax, SECTION_FOOTER
    ret

.csdi_no:
    mov     eax, -1
    ret

; ═══════════════════════════════════════════════════════════
; process_mmap — Process entire mmap'd file (generic/slow path)
; Uses [mmap_base] and [mmap_size] globals.
; Lines are referenced directly in the mmap'd region (true zero-copy).
; ═══════════════════════════════════════════════════════════
process_mmap:
    push    rbx
    push    r14
    push    r15

    mov     r14, [mmap_base]        ; data pointer
    mov     r15, [mmap_size]        ; total size
    xor     r8d, r8d                ; current offset
    mov     [line_start], r8        ; start of current line

    ; Load newline pattern for SIMD
    movdqa  xmm1, [rel newline_pattern]

.pm_scan_simd:
    mov     rax, r15
    sub     rax, r8
    cmp     rax, 16
    jl      .pm_scan_scalar

    movdqu  xmm0, [r14 + r8]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0

    test    eax, eax
    jnz     .pm_simd_found_nl

    add     r8, 16
    jmp     .pm_scan_simd

.pm_simd_found_nl:
    bsf     ecx, eax                ; position of \n in window
    ; Line is [line_start .. r8+ecx)
    lea     rax, [r14]
    add     rax, [line_start]
    mov     [line_ptr], rax
    mov     rax, r8
    add     rax, rcx
    sub     rax, [line_start]
    mov     [line_len], rax

    ; Process this line
    push    r8
    push    rcx
    call    process_line_direct
    pop     rcx
    pop     r8

    ; Advance past newline
    add     r8, rcx
    inc     r8
    mov     [line_start], r8
    jmp     .pm_scan_simd

.pm_scan_scalar:
    cmp     r8, r15
    jge     .pm_done

    cmp     byte [r14 + r8], 10
    je      .pm_scalar_nl

    inc     r8
    jmp     .pm_scan_scalar

.pm_scalar_nl:
    ; Line is [line_start .. r8)
    lea     rax, [r14]
    add     rax, [line_start]
    mov     [line_ptr], rax
    mov     rax, r8
    sub     rax, [line_start]
    mov     [line_len], rax

    push    r8
    call    process_line_direct
    pop     r8

    inc     r8
    mov     [line_start], r8
    jmp     .pm_scan_scalar

.pm_done:
    ; Handle remaining data (no trailing newline)
    mov     rax, [line_start]
    cmp     rax, r15
    jge     .pm_exit

    ; There's a partial line at the end
    lea     rax, [r14]
    add     rax, [line_start]
    mov     [line_ptr], rax
    mov     rax, r15
    sub     rax, [line_start]
    mov     [line_len], rax

    call    process_line_direct

.pm_exit:
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; process_fd(edi=fd) — Read all data from fd, process lines
; Direct zero-copy: when a complete line fits within read_buf,
; we point line processing directly at read_buf data instead
; of copying through line_buf. Only lines that span read
; boundaries use line_buf.
; ═══════════════════════════════════════════════════════════
process_fd:
    push    rbx
    push    r14
    push    r15

    mov     ebx, edi                ; fd to read from
    lea     r14, [rel line_buf]

.pf_read_loop:
    ; Read a chunk
    mov     edi, ebx
    lea     rsi, [rel read_buf]
    mov     edx, READ_BUF_SIZE
    call    asm_read

    test    rax, rax
    js      .pf_read_error
    jz      .pf_read_eof

    ; rax = bytes read
    xor     r8d, r8d                ; offset = 0
    mov     r9, rax                 ; total bytes
    mov     r15, rax                ; save for later use

    ; Track line start within read_buf
    ; r8 = current scan position, [line_start] = start of current line in read_buf
    mov     [line_start], r8

    ; Load newline comparison pattern for SIMD
    movdqa  xmm1, [rel newline_pattern]

.pf_scan_simd:
    mov     rax, r9
    sub     rax, r8
    cmp     rax, 16
    jl      .pf_scan_scalar

    lea     rdi, [rel read_buf]
    add     rdi, r8
    movdqu  xmm0, [rdi]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0

    test    eax, eax
    jnz     .pf_simd_found_nl

    ; No newline in 16 bytes
    ; If line_buf_used > 0, copy to line_buf (spanning line)
    cmp     qword [line_buf_used], 0
    jne     .pf_simd_copy_to_lb

    ; Direct mode: just advance
    add     r8, 16
    jmp     .pf_scan_simd

.pf_simd_copy_to_lb:
    ; Copy 16 bytes to line_buf
    mov     rcx, [line_buf_used]
    lea     rdx, [rcx + 16]
    cmp     rdx, LINE_BUF_SIZE
    jge     .pf_line_overflow
    movdqu  xmm2, [rdi]
    movdqu  [r14 + rcx], xmm2
    add     qword [line_buf_used], 16
    add     r8, 16
    jmp     .pf_scan_simd

.pf_simd_found_nl:
    bsf     ecx, eax                ; position of first \n within 16-byte window
    ; Newline is at read_buf[r8 + ecx]

    ; Check if we have a spanning line (line_buf_used > 0)
    cmp     qword [line_buf_used], 0
    jne     .pf_simd_spanning_line

    ; Direct mode: line is read_buf[line_start .. r8+ecx)
    ; Set up line_ptr and line_len for process_line_direct
    lea     rax, [rel read_buf]
    add     rax, [line_start]
    mov     [line_ptr], rax
    mov     rax, r8
    add     rax, rcx
    sub     rax, [line_start]
    mov     [line_len], rax

    push    r8
    push    r9
    push    rcx
    call    process_line_direct
    pop     rcx
    pop     r9
    pop     r8

    ; Advance past newline
    add     r8, rcx
    inc     r8
    mov     [line_start], r8
    jmp     .pf_scan_simd

.pf_simd_spanning_line:
    ; Copy bytes before newline to line_buf, then process line_buf
    mov     rdx, [line_buf_used]
    lea     rax, [rdx + rcx]
    cmp     rax, LINE_BUF_SIZE
    jge     .pf_line_overflow

    test    ecx, ecx
    jz      .pf_simd_span_emit

    lea     rsi, [rel read_buf]
    add     rsi, r8
    lea     rdi, [r14 + rdx]
    push    rcx
    push    r8
    push    r9
    mov     rax, rcx
    mov     rcx, rax
    rep     movsb
    pop     r9
    pop     r8
    pop     rcx
    add     [line_buf_used], rcx

.pf_simd_span_emit:
    ; Process spanning line from line_buf
    mov     rax, r14                ; line_buf
    mov     [line_ptr], rax
    mov     rax, [line_buf_used]
    mov     [line_len], rax

    push    r8
    push    r9
    push    rcx
    call    process_line_direct
    pop     rcx
    pop     r9
    pop     r8

    add     r8, rcx
    inc     r8
    mov     qword [line_buf_used], 0
    mov     [line_start], r8
    jmp     .pf_scan_simd

.pf_scan_scalar:
    cmp     r8, r9
    jge     .pf_chunk_done

    lea     rsi, [rel read_buf]
    movzx   eax, byte [rsi + r8]
    cmp     al, 10
    je      .pf_scalar_found_nl

    ; No newline: if in spanning mode, copy byte to line_buf
    cmp     qword [line_buf_used], 0
    jne     .pf_scalar_copy_lb

    ; Direct mode: just advance
    inc     r8
    jmp     .pf_scan_scalar

.pf_scalar_copy_lb:
    mov     rcx, [line_buf_used]
    cmp     rcx, LINE_BUF_SIZE
    jge     .pf_line_overflow
    mov     [r14 + rcx], al
    inc     qword [line_buf_used]
    inc     r8
    jmp     .pf_scan_scalar

.pf_scalar_found_nl:
    cmp     qword [line_buf_used], 0
    jne     .pf_scalar_spanning

    ; Direct mode line
    lea     rax, [rel read_buf]
    add     rax, [line_start]
    mov     [line_ptr], rax
    mov     rax, r8
    sub     rax, [line_start]
    mov     [line_len], rax

    push    r8
    push    r9
    call    process_line_direct
    pop     r9
    pop     r8

    inc     r8
    mov     [line_start], r8
    jmp     .pf_scan_scalar

.pf_scalar_spanning:
    ; Process spanning line from line_buf
    mov     rax, r14
    mov     [line_ptr], rax
    mov     rax, [line_buf_used]
    mov     [line_len], rax

    push    r8
    push    r9
    call    process_line_direct
    pop     r9
    pop     r8

    inc     r8
    mov     qword [line_buf_used], 0
    mov     [line_start], r8
    jmp     .pf_scan_scalar

.pf_chunk_done:
    ; End of read chunk. If there's a partial line in direct mode
    ; (line_buf_used == 0 and line_start < r9), copy remainder to line_buf
    cmp     qword [line_buf_used], 0
    jne     .pf_read_loop           ; already in spanning mode, go read more

    mov     rax, [line_start]
    cmp     rax, r9
    jge     .pf_read_loop           ; nothing leftover

    ; Copy read_buf[line_start..r9) to line_buf
    mov     rcx, r9
    sub     rcx, rax
    lea     rsi, [rel read_buf]
    add     rsi, rax
    lea     rdi, [r14]
    push    rcx
    rep     movsb
    pop     rcx
    mov     [line_buf_used], rcx
    jmp     .pf_read_loop

.pf_read_eof:
.pf_done:
    pop     r15
    pop     r14
    pop     rbx
    ret

.pf_read_error:
    mov     ebp, 1
    jmp     .pf_done

.pf_line_overflow:
    ; Process overflow line from line_buf
    mov     rax, r14
    mov     [line_ptr], rax
    mov     rax, [line_buf_used]
    mov     [line_len], rax
    push    r8
    push    r9
    call    process_line_direct
    pop     r9
    pop     r8
    mov     qword [line_buf_used], 0
    mov     [line_start], r8
    jmp     .pf_scan_scalar

; ═══════════════════════════════════════════════════════════
; process_line_direct — Process line at [line_ptr] with length [line_len]
; Zero-copy: reads directly from read_buf (or line_buf for spanning lines)
; Checks section delimiters, applies numbering style, outputs
; ═══════════════════════════════════════════════════════════
process_line_direct:
    push    rbx
    push    r14
    push    r15

    ; Check for section delimiter if delimiter is active
    cmp     byte [delim_len], 0
    je      .pcl_not_delimiter

    ; Check if line is a section delimiter
    call    check_section_delimiter_direct
    cmp     eax, -1
    je      .pcl_not_delimiter

    ; It's a section delimiter — update state
    mov     [cur_section], al

    ; Reset line number unless -p
    cmp     byte [no_renumber], 0
    jne     .pcl_delim_no_reset
    mov     rax, [start_num]
    mov     [line_number], rax
    mov     qword [blank_count], 0
    mov     byte [prefix_valid], 0  ; invalidate prefix cache
.pcl_delim_no_reset:

    ; Output empty line (delimiter lines become blank)
    call    emit_newline
    jmp     .pcl_done

.pcl_not_delimiter:
    ; Determine the numbering style for current section
    movzx   eax, byte [cur_section]
    cmp     al, SECTION_HEADER
    je      .pcl_use_header_style
    cmp     al, SECTION_FOOTER
    je      .pcl_use_footer_style
    ; Default: body
    movzx   eax, byte [body_style]
    jmp     .pcl_have_style

.pcl_use_header_style:
    movzx   eax, byte [header_style]
    jmp     .pcl_have_style

.pcl_use_footer_style:
    movzx   eax, byte [footer_style]

.pcl_have_style:
    cmp     al, STYLE_NONE
    je      .pcl_no_number

    cmp     al, STYLE_NONEMPTY
    je      .pcl_check_nonempty

    ; STYLE_ALL
    cmp     qword [line_len], 0
    jne     .pcl_do_number

    ; Blank line — apply -l logic
    inc     qword [blank_count]
    mov     rax, [blank_count]
    cmp     rax, [join_blank]
    jl      .pcl_no_number
    mov     qword [blank_count], 0
    jmp     .pcl_do_number

.pcl_check_nonempty:
    cmp     qword [line_len], 0
    je      .pcl_no_number

.pcl_do_number:
    ; Reset blank count for non-blank lines
    cmp     qword [line_len], 0
    je      .pcl_skip_reset
    mov     qword [blank_count], 0
.pcl_skip_reset:
    ; Emit number + separator + line content + \n
    call    emit_number
    call    emit_separator
    call    emit_content_direct
    call    emit_newline

    ; Advance line number
    mov     rax, [line_number]
    add     rax, [line_incr]
    mov     [line_number], rax
    jmp     .pcl_done

.pcl_no_number:
    call    emit_blank_prefix
    call    emit_content_direct
    call    emit_newline

.pcl_done:
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; process_last_line — Handle remaining data (no trailing newline)
; ═══════════════════════════════════════════════════════════
process_last_line:
    ; Set up line_ptr/line_len from line_buf/line_buf_used
    lea     rax, [rel line_buf]
    mov     [line_ptr], rax
    mov     rax, [line_buf_used]
    mov     [line_len], rax
    call    process_line_direct
    ret

; ═══════════════════════════════════════════════════════════
; check_section_delimiter — Check if line_buf matches a section delimiter
; Returns eax = SECTION_HEADER(0), SECTION_BODY(1), SECTION_FOOTER(2), or -1
; Section delimiter patterns (with default "\:"):
;   Header: \:\:\: (3x delimiter pair)
;   Body:   \:\:   (2x delimiter pair)
;   Footer: \:     (1x delimiter pair)
; ═══════════════════════════════════════════════════════════
check_section_delimiter:
    push    rbx
    push    r14

    movzx   eax, byte [delim_len]
    test    al, al
    jz      .csd_no_match

    ; delimiter pair length
    movzx   ebx, byte [delim_len]   ; 2 for default

    ; Check header (3x delimiter)
    mov     rax, [line_buf_used]
    mov     rcx, rbx
    imul    rcx, 3                  ; 3 * delim_len
    cmp     rax, rcx
    jne     .csd_check_body

    ; Verify 3x delimiter
    lea     rsi, [rel line_buf]
    mov     ecx, 3
    call    csd_verify_repeats
    test    eax, eax
    jz      .csd_header

.csd_check_body:
    ; Check body (2x delimiter)
    mov     rax, [line_buf_used]
    mov     rcx, rbx
    imul    rcx, 2                  ; 2 * delim_len
    cmp     rax, rcx
    jne     .csd_check_footer

    lea     rsi, [rel line_buf]
    mov     ecx, 2
    call    csd_verify_repeats
    test    eax, eax
    jz      .csd_body

.csd_check_footer:
    ; Check footer (1x delimiter)
    mov     rax, [line_buf_used]
    cmp     rax, rbx
    jne     .csd_no_match

    lea     rsi, [rel line_buf]
    mov     ecx, 1
    call    csd_verify_repeats
    test    eax, eax
    jz      .csd_footer

.csd_no_match:
    mov     eax, -1
    pop     r14
    pop     rbx
    ret

.csd_header:
    mov     eax, SECTION_HEADER
    pop     r14
    pop     rbx
    ret

.csd_body:
    mov     eax, SECTION_BODY
    pop     r14
    pop     rbx
    ret

.csd_footer:
    mov     eax, SECTION_FOOTER
    pop     r14
    pop     rbx
    ret

; csd_verify_repeats(rsi=line data, ecx=repeat_count, ebx=delim_len)
; Verifies that the data consists of exactly ecx repetitions of the delimiter
; Returns eax=0 if match, eax=-1 if no match
csd_verify_repeats:
    push    r14
    push    r15
    mov     r14, rsi                ; line pointer
    mov     r15d, ecx               ; repeat count

.cvr_repeat:
    test    r15d, r15d
    jz      .cvr_match

    ; Compare delimiter chars
    movzx   eax, byte [delim_char1]
    cmp     al, [r14]
    jne     .cvr_no
    inc     r14

    ; Check second char if delim_len == 2
    cmp     ebx, 2
    jl      .cvr_next
    movzx   eax, byte [delim_char2]
    cmp     al, [r14]
    jne     .cvr_no
    inc     r14

.cvr_next:
    dec     r15d
    jmp     .cvr_repeat

.cvr_match:
    xor     eax, eax
    pop     r15
    pop     r14
    ret

.cvr_no:
    mov     eax, -1
    pop     r15
    pop     r14
    ret

; ═══════════════════════════════════════════════════════════
; check_section_delimiter_direct — Uses [line_ptr]/[line_len]
; Returns eax = SECTION_HEADER(0), SECTION_BODY(1), SECTION_FOOTER(2), or -1
; ═══════════════════════════════════════════════════════════
check_section_delimiter_direct:
    push    rbx
    push    r14

    movzx   eax, byte [delim_len]
    test    al, al
    jz      .csdd_no_match

    movzx   ebx, byte [delim_len]

    ; Check header (3x delimiter)
    mov     rax, [line_len]
    mov     rcx, rbx
    imul    rcx, 3
    cmp     rax, rcx
    jne     .csdd_check_body
    mov     rsi, [line_ptr]
    mov     ecx, 3
    call    csd_verify_repeats
    test    eax, eax
    jz      .csdd_header

.csdd_check_body:
    mov     rax, [line_len]
    mov     rcx, rbx
    imul    rcx, 2
    cmp     rax, rcx
    jne     .csdd_check_footer
    mov     rsi, [line_ptr]
    mov     ecx, 2
    call    csd_verify_repeats
    test    eax, eax
    jz      .csdd_body

.csdd_check_footer:
    mov     rax, [line_len]
    cmp     rax, rbx
    jne     .csdd_no_match
    mov     rsi, [line_ptr]
    mov     ecx, 1
    call    csd_verify_repeats
    test    eax, eax
    jz      .csdd_footer

.csdd_no_match:
    mov     eax, -1
    pop     r14
    pop     rbx
    ret
.csdd_header:
    mov     eax, SECTION_HEADER
    pop     r14
    pop     rbx
    ret
.csdd_body:
    mov     eax, SECTION_BODY
    pop     r14
    pop     rbx
    ret
.csdd_footer:
    mov     eax, SECTION_FOOTER
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; emit_number — Format and emit the current line number
; Uses a cached prefix buffer for O(1) increments.
;
; prefix_buf layout: [padding][digits] (total = num_width bytes)
; prefix_valid: 0 = needs rebuild, 1 = can use cached
; prefix_total_len: total bytes in prefix_buf
; prefix_digit_start: offset of first digit in prefix_buf
; prefix_digit_end: offset past last digit in prefix_buf
; ═══════════════════════════════════════════════════════════
emit_number:
    push    rbx
    push    r14
    push    r15

    ; Check if we can use the cached prefix
    cmp     byte [prefix_valid], 1
    jne     .en_rebuild

    ; Fast path: increment the cached number in-place
    ; Only valid for increment=1 and positive numbers
    mov     rax, [line_number]
    test    rax, rax
    js      .en_rebuild              ; negative, rebuild

    ; Increment last digit with carry
    mov     rcx, [prefix_digit_end]
    dec     rcx                     ; point to last digit
    lea     rdi, [rel prefix_buf]

.en_carry_loop:
    cmp     rcx, [prefix_digit_start]
    jl      .en_carry_overflow      ; all digits carried, need rebuild
    movzx   eax, byte [rdi + rcx]
    cmp     al, '9'
    jne     .en_carry_inc
    ; Digit is 9, set to 0 and carry
    mov     byte [rdi + rcx], '0'
    dec     rcx
    jmp     .en_carry_loop

.en_carry_inc:
    inc     al
    mov     [rdi + rcx], al
    jmp     .en_emit_cached

.en_carry_overflow:
    ; Need one more digit — check if we have padding to steal
    mov     rcx, [prefix_digit_start]
    test    rcx, rcx
    jz      .en_rebuild              ; no padding, must rebuild
    dec     rcx
    mov     [prefix_digit_start], rcx
    lea     rdi, [rel prefix_buf]
    mov     byte [rdi + rcx], '1'   ; the carry digit
    jmp     .en_emit_cached

.en_emit_cached:
    ; Copy prefix_buf to out_buf
    mov     rcx, [prefix_total_len]
    lea     rax, [r12 + rcx]
    cmp     rax, OUT_BUF_SIZE
    jl      .en_ec_go
    push    rcx
    call    flush_output
    pop     rcx
.en_ec_go:
    lea     rdi, [rel out_buf]
    add     rdi, r12
    lea     rsi, [rel prefix_buf]
    push    rcx
    rep     movsb
    pop     rcx
    add     r12, rcx

    pop     r15
    pop     r14
    pop     rbx
    ret

.en_rebuild:
    ; Full rebuild of prefix_buf
    ; Convert line number to decimal string using fast multiply
    mov     rax, [line_number]
    xor     r15d, r15d              ; negative flag
    test    rax, rax
    jns     .en_positive
    mov     r15d, 1
    neg     rax
.en_positive:
    lea     rdi, [rel itoa_buf + 31]
    mov     byte [rdi], 0
    xor     ecx, ecx

.en_itoa_loop:
    ; Fast divide by 10 using multiply by magic
    mov     r14, rax
    mov     rdx, 0xCCCCCCCCCCCCCCCD
    mul     rdx
    shr     rdx, 3                  ; rdx = rax / 10
    ; remainder = r14 - rdx * 10
    lea     r11, [rdx + rdx*4]
    add     r11, r11                ; r11 = rdx * 10
    mov     rax, r14
    sub     rax, r11                ; rax = remainder
    add     al, '0'
    dec     rdi
    mov     [rdi], al
    inc     ecx
    mov     rax, rdx                ; continue with quotient
    test    rax, rax
    jnz     .en_itoa_loop

    ; If negative, prepend '-'
    test    r15d, r15d
    jz      .en_no_neg
    dec     rdi
    mov     byte [rdi], '-'
    inc     ecx
.en_no_neg:
    ; rdi = start of number string, ecx = length (digit_len)
    mov     r14, rdi                ; number string ptr
    mov     ebx, ecx                ; number string length

    ; Get width
    mov     r15, [num_width]

    ; Build prefix_buf based on format
    movzx   eax, byte [num_format]
    cmp     al, FMT_LN
    je      .en_build_ln
    cmp     al, FMT_RZ
    je      .en_build_rz

    ; FMT_RN — [spaces][digits]
.en_build_rn:
    lea     rdi, [rel prefix_buf]
    ; Fill with spaces
    mov     rcx, r15
    sub     rcx, rbx
    test    rcx, rcx
    jle     .en_rn_no_pad
    push    rcx
    mov     al, ' '
    rep     stosb
    pop     rcx
    ; rdi now points past spaces
    ; Copy digits
    mov     rsi, r14
    movzx   ecx, bl
    mov     rax, r15
    sub     rax, rbx
    mov     [prefix_digit_start], rax
    push    rcx
    rep     movsb
    pop     rcx
    mov     rax, r15
    mov     [prefix_digit_end], rax
    mov     [prefix_total_len], rax
    jmp     .en_build_done

.en_rn_no_pad:
    ; Number wider than width — just emit digits
    mov     rsi, r14
    mov     ecx, ebx
    mov     qword [prefix_digit_start], 0
    push    rcx
    rep     movsb
    pop     rcx
    movzx   rax, bl
    mov     [prefix_digit_end], rax
    mov     [prefix_total_len], rax
    jmp     .en_build_done

.en_build_ln:
    ; FMT_LN — [digits][spaces]
    lea     rdi, [rel prefix_buf]
    mov     qword [prefix_digit_start], 0
    mov     rsi, r14
    movzx   ecx, bl
    push    rcx
    rep     movsb
    pop     rcx
    movzx   rax, bl
    mov     [prefix_digit_end], rax
    ; Fill remaining with spaces
    mov     rcx, r15
    sub     rcx, rbx
    test    rcx, rcx
    jle     .en_ln_no_pad
    push    rcx
    mov     al, ' '
    rep     stosb
    pop     rcx
.en_ln_no_pad:
    mov     rax, r15
    movzx   rcx, bl
    cmp     rax, rcx
    jge     .en_ln_ok
    mov     rax, rcx
.en_ln_ok:
    mov     [prefix_total_len], rax
    ; Don't cache ln format (increment changes trailing spaces)
    mov     byte [prefix_valid], 0
    jmp     .en_emit_prefix

.en_build_rz:
    ; FMT_RZ — [zeros][digits] or [-][zeros][digits]
    lea     rdi, [rel prefix_buf]
    cmp     byte [r14], '-'
    je      .en_rz_neg

    ; Fill leading zeros
    mov     rcx, r15
    sub     rcx, rbx
    test    rcx, rcx
    jle     .en_rz_no_pad
    push    rcx
    mov     al, '0'
    rep     stosb
    pop     rcx
    mov     rax, r15
    sub     rax, rbx
    mov     [prefix_digit_start], rax
    ; Copy digits
    mov     rsi, r14
    movzx   ecx, bl
    push    rcx
    rep     movsb
    pop     rcx
    mov     rax, r15
    mov     [prefix_digit_end], rax
    mov     [prefix_total_len], rax
    jmp     .en_build_done

.en_rz_no_pad:
    mov     rsi, r14
    mov     ecx, ebx
    mov     qword [prefix_digit_start], 0
    push    rcx
    rep     movsb
    pop     rcx
    movzx   rax, bl
    mov     [prefix_digit_end], rax
    mov     [prefix_total_len], rax
    jmp     .en_build_done

.en_rz_neg:
    ; '-' + zeros + digits
    mov     byte [rdi], '-'
    inc     rdi
    inc     r14                     ; skip '-' in source
    dec     ebx                     ; adjust digit length
    mov     rcx, r15
    dec     rcx                     ; account for '-'
    sub     rcx, rbx
    test    rcx, rcx
    jle     .en_rz_neg_no_pad
    push    rcx
    mov     al, '0'
    rep     stosb
    pop     rcx
.en_rz_neg_no_pad:
    mov     rsi, r14
    movzx   ecx, bl
    push    rcx
    rep     movsb
    pop     rcx
    ; Don't cache negative numbers
    mov     rax, r15
    mov     [prefix_total_len], rax
    mov     byte [prefix_valid], 0
    jmp     .en_emit_prefix

.en_build_done:
    ; Enable cache only for increment=1, positive numbers, rn or rz format
    mov     byte [prefix_valid], 0
    cmp     qword [line_incr], 1
    jne     .en_emit_prefix
    mov     rax, [line_number]
    test    rax, rax
    js      .en_emit_prefix
    mov     byte [prefix_valid], 1

.en_emit_prefix:
    ; Copy prefix_buf to out_buf
    mov     rcx, [prefix_total_len]
    lea     rax, [r12 + rcx]
    cmp     rax, OUT_BUF_SIZE
    jl      .en_ep_go
    push    rcx
    call    flush_output
    pop     rcx
.en_ep_go:
    lea     rdi, [rel out_buf]
    add     rdi, r12
    lea     rsi, [rel prefix_buf]
    push    rcx
    rep     movsb
    pop     rcx
    add     r12, rcx

    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; emit_separator — Emit the separator string to out_buf
; ═══════════════════════════════════════════════════════════
emit_separator:
    push    rbx
    mov     rbx, [sep_len]
    test    rbx, rbx
    jz      .es_done
    ; Ensure space
    lea     rax, [r12 + rbx]
    cmp     rax, OUT_BUF_SIZE
    jl      .es_go
    push    rbx
    call    flush_output
    pop     rbx
.es_go:
    lea     rdi, [rel out_buf]
    add     rdi, r12
    lea     rsi, [rel separator]
    mov     rcx, rbx
    rep     movsb
    add     r12, rbx
.es_done:
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; emit_blank_prefix — Emit (width + sep_len) spaces for non-numbered lines
; ═══════════════════════════════════════════════════════════
emit_blank_prefix:
    push    rbx
    push    r14
    mov     rbx, [num_width]
    add     rbx, [sep_len]
    test    rbx, rbx
    jz      .ebp_done
    xor     r14d, r14d              ; bytes written

.ebp_chunk:
    mov     rax, OUT_BUF_SIZE
    sub     rax, r12
    mov     rcx, rbx
    sub     rcx, r14
    test    rcx, rcx
    jle     .ebp_done

    test    rax, rax
    jg      .ebp_has_space
    push    rcx
    call    flush_output
    pop     rcx
    mov     rax, OUT_BUF_SIZE
.ebp_has_space:
    cmp     rcx, rax
    jle     .ebp_fill
    mov     rcx, rax
.ebp_fill:
    lea     rdi, [rel out_buf]
    add     rdi, r12
    push    rcx
    mov     al, ' '
    rep     stosb
    pop     rcx
    add     r12, rcx
    add     r14, rcx
    jmp     .ebp_chunk

.ebp_done:
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; emit_line_content — Emit line_buf contents to out_buf
; ═══════════════════════════════════════════════════════════
emit_line_content:
    push    rbx
    push    r14
    push    r15
    mov     rbx, [line_buf_used]
    test    rbx, rbx
    jz      .elc_done
    lea     r14, [rel line_buf]
    xor     r15d, r15d              ; offset into line_buf

.elc_chunk:
    ; How much space in out_buf?
    mov     rax, OUT_BUF_SIZE
    sub     rax, r12
    ; How much remaining to copy?
    mov     rcx, rbx
    sub     rcx, r15
    test    rcx, rcx
    jle     .elc_done

    ; If no space, flush
    test    rax, rax
    jg      .elc_has_space
    push    rcx
    call    flush_output
    pop     rcx
    mov     rax, OUT_BUF_SIZE
.elc_has_space:
    ; Copy min(remaining, space) bytes
    cmp     rcx, rax
    jle     .elc_copy
    mov     rcx, rax
.elc_copy:
    lea     rdi, [rel out_buf]
    add     rdi, r12
    lea     rsi, [r14 + r15]
    push    rcx
    rep     movsb
    pop     rcx
    add     r12, rcx
    add     r15, rcx
    jmp     .elc_chunk

.elc_done:
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; emit_content_direct — Emit [line_ptr]/[line_len] to out_buf (zero-copy)
; ═══════════════════════════════════════════════════════════
emit_content_direct:
    push    rbx
    push    r14
    push    r15
    mov     rbx, [line_len]
    test    rbx, rbx
    jz      .ecd_done
    mov     r14, [line_ptr]
    xor     r15d, r15d

.ecd_chunk:
    mov     rax, OUT_BUF_SIZE
    sub     rax, r12
    mov     rcx, rbx
    sub     rcx, r15
    test    rcx, rcx
    jle     .ecd_done

    test    rax, rax
    jg      .ecd_has_space
    push    rcx
    call    flush_output
    pop     rcx
    mov     rax, OUT_BUF_SIZE
.ecd_has_space:
    cmp     rcx, rax
    jle     .ecd_copy
    mov     rcx, rax
.ecd_copy:
    lea     rdi, [rel out_buf]
    add     rdi, r12
    lea     rsi, [r14 + r15]
    push    rcx
    rep     movsb
    pop     rcx
    add     r12, rcx
    add     r15, rcx
    jmp     .ecd_chunk

.ecd_done:
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; emit_newline — Emit a newline character to out_buf
; ═══════════════════════════════════════════════════════════
emit_newline:
    call    ensure_out_space_1
    lea     rdi, [rel out_buf]
    mov     byte [rdi + r12], 10
    inc     r12
    ret

; ═══════════════════════════════════════════════════════════
; ensure_out_space_1 — Flush output buffer if near full
; Preserves: rcx, rbx, r14, r15
; ═══════════════════════════════════════════════════════════
ensure_out_space_1:
    cmp     r12, OUT_BUF_SIZE - 1
    jl      .eos_ok
    ; Need to flush
    push    rcx
    push    rbx
    push    r14
    push    r15
    call    flush_output
    pop     r15
    pop     r14
    pop     rbx
    pop     rcx
.eos_ok:
    ret

; ═══════════════════════════════════════════════════════════
; flush_output — Write out_buf[0..r12) to stdout
; Returns eax=0 on success, eax=-1 on error
; ═══════════════════════════════════════════════════════════
flush_output:
    test    r12, r12
    jz      .fo_ok
    mov     rdi, STDOUT
    lea     rsi, [rel out_buf]
    mov     rdx, r12
    call    asm_write_all
    test    rax, rax
    js      .fo_err
    xor     r12d, r12d
.fo_ok:
    xor     eax, eax
    ret
.fo_err:
    mov     eax, -1
    ret

; ═══════════════════════════════════════════════════════════
; String utility functions
; ═══════════════════════════════════════════════════════════

; strcmp(rdi=str1, rsi=str2) -> eax=0 if equal
strcmp:
.sc_loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .sc_ne
    test    al, al
    jz      .sc_eq
    inc     rdi
    inc     rsi
    jmp     .sc_loop
.sc_eq:
    xor     eax, eax
    ret
.sc_ne:
    mov     eax, 1
    ret

; strlen(rdi=str) -> rax=length
strlen:
    xor     rax, rax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; write_stderr(rdi=buf, rsi=len) — write to stderr
write_stderr:
    push    rdi
    push    rsi
    mov     rdx, rsi
    mov     rsi, rdi
    mov     rdi, STDERR
    call    asm_write_all
    pop     rsi
    pop     rdi
    ret

; ═══════════════════════════════════════════════════════════
; Error message functions
; ═══════════════════════════════════════════════════════════

; err_unrecognized_option(rsi=option_string)
err_unrecognized_option:
    push    rbx
    mov     rbx, rsi

    lea     rdi, [rel str_prefix]
    mov     rsi, str_prefix_len
    call    write_stderr

    lea     rdi, [rel str_unrecognized]
    mov     rsi, str_unrecognized_len
    call    write_stderr

    mov     rdi, rbx
    call    strlen
    mov     rsi, rax
    mov     rdi, rbx
    call    write_stderr

    lea     rdi, [rel str_quote_nl]
    mov     rsi, 2
    call    write_stderr

    lea     rdi, [rel str_try_help]
    mov     rsi, str_try_help_len
    call    write_stderr

    pop     rbx
    ret

; err_invalid_option(rsi=option_string e.g. "-Z")
err_invalid_option:
    push    rbx
    mov     rbx, rsi

    lea     rdi, [rel str_prefix]
    mov     rsi, str_prefix_len
    call    write_stderr

    lea     rdi, [rel str_invalid_opt]
    mov     rsi, str_invalid_opt_len
    call    write_stderr

    ; The option character
    lea     rdi, [rbx + 1]
    mov     rsi, 1
    call    write_stderr

    lea     rdi, [rel str_quote_nl]
    mov     rsi, 2
    call    write_stderr

    lea     rdi, [rel str_try_help]
    mov     rsi, str_try_help_len
    call    write_stderr

    pop     rbx
    ret

; err_file(rdi=filename, esi=errno)
err_file:
    push    rbx
    push    r13
    mov     rbx, rdi
    mov     r13d, esi

    lea     rdi, [rel str_prefix]
    mov     rsi, str_prefix_len
    call    write_stderr

    mov     rdi, rbx
    call    strlen
    mov     rsi, rax
    mov     rdi, rbx
    call    write_stderr

    lea     rdi, [rel str_colon_space]
    mov     rsi, 2
    call    write_stderr

    mov     edi, r13d
    call    strerror
    mov     rbx, rax
    mov     rdi, rax
    call    strlen
    mov     rsi, rax
    mov     rdi, rbx
    call    write_stderr

    lea     rdi, [rel str_newline_ch]
    mov     rsi, 1
    call    write_stderr

    pop     r13
    pop     rbx
    ret

; print_error_simple(rdi=null-terminated string)
print_error_simple:
    push    rbx
    mov     rbx, rdi

    lea     rdi, [rel str_prefix]
    mov     rsi, str_prefix_len
    call    write_stderr

    mov     rdi, rbx
    call    strlen
    mov     rsi, rax
    mov     rdi, rbx
    call    write_stderr

    lea     rdi, [rel str_newline_ch]
    mov     rsi, 1
    call    write_stderr

    pop     rbx
    ret

; strerror(edi=errno) -> rax=string pointer
strerror:
    cmp     edi, 1
    je      .se_eperm
    cmp     edi, 2
    je      .se_enoent
    cmp     edi, 5
    je      .se_eio
    cmp     edi, 9
    je      .se_ebadf
    cmp     edi, 12
    je      .se_enomem
    cmp     edi, 13
    je      .se_eacces
    cmp     edi, 20
    je      .se_enotdir
    cmp     edi, 21
    je      .se_eisdir
    cmp     edi, 22
    je      .se_einval
    cmp     edi, 24
    je      .se_emfile
    cmp     edi, 36
    je      .se_enametoolong
    lea     rax, [rel str_eunknown]
    ret
.se_eperm:
    lea     rax, [rel str_eperm]
    ret
.se_enoent:
    lea     rax, [rel str_enoent]
    ret
.se_eio:
    lea     rax, [rel str_eio]
    ret
.se_ebadf:
    lea     rax, [rel str_ebadf]
    ret
.se_enomem:
    lea     rax, [rel str_enomem]
    ret
.se_eacces:
    lea     rax, [rel str_eacces]
    ret
.se_enotdir:
    lea     rax, [rel str_enotdir]
    ret
.se_eisdir:
    lea     rax, [rel str_eisdir]
    ret
.se_einval:
    lea     rax, [rel str_einval]
    ret
.se_emfile:
    lea     rax, [rel str_emfile]
    ret
.se_enametoolong:
    lea     rax, [rel str_enametoolong]
    ret

; ─── Data Section ────────────────────────────────────────
section .data

align 16
newline_pattern:
    times 16 db 10

str_prefix:     db "nl: "
str_prefix_len equ $ - str_prefix

str_newline_ch: db 10
str_colon_space: db ": "

str_help_flag:  db "--help", 0
str_version_flag: db "--version", 0

str_unrecognized: db "unrecognized option '"
str_unrecognized_len equ $ - str_unrecognized

str_quote_nl:   db "'", 10

str_write_error: db "write error", 0

str_try_help: db "Try 'nl --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_invalid_opt: db "invalid option -- '"
str_invalid_opt_len equ $ - str_invalid_opt

str_opt_requires_arg: db "option requires an argument -- '"
str_opt_requires_arg_len equ $ - str_opt_requires_arg

str_invalid_style: db "invalid numbering style: '"
str_invalid_style_len equ $ - str_invalid_style

str_invalid_format: db "invalid line numbering format: '"
str_invalid_format_len equ $ - str_invalid_format

str_invalid_number: db "invalid number: '"
str_invalid_number_len equ $ - str_invalid_number

; Long option names (without --)
str_lo_body:        db "body-numbering", 0
str_lo_footer:      db "footer-numbering", 0
str_lo_header:      db "header-numbering", 0
str_lo_delim:       db "section-delimiter", 0
str_lo_incr:        db "line-increment", 0
str_lo_join:        db "join-blank-lines", 0
str_lo_numfmt:      db "number-format", 0
str_lo_norenumber:  db "no-renumber", 0
str_lo_sep:         db "number-separator", 0
str_lo_startnum:    db "starting-line-number", 0
str_lo_width:       db "number-width", 0

; ── Help / Version text ──
; @@DATA_START@@
help_text:
    db "Usage: nl [OPTION]... [FILE]...", 10
    db "Write each FILE to standard output, with line numbers added.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -b, --body-numbering=STYLE      use STYLE for numbering body lines", 10
    db "  -d, --section-delimiter=CC      use CC for logical page delimiters", 10
    db "  -f, --footer-numbering=STYLE    use STYLE for numbering footer lines", 10
    db "  -h, --header-numbering=STYLE    use STYLE for numbering header lines", 10
    db "  -i, --line-increment=NUMBER     line number increment at each line", 10
    db "  -l, --join-blank-lines=NUMBER   group of NUMBER empty lines counted as one", 10
    db "  -n, --number-format=FORMAT      insert line numbers according to FORMAT", 10
    db "  -p, --no-renumber               do not reset line numbers for each section", 10
    db "  -s, --number-separator=STRING   add STRING after (possible) line number", 10
    db "  -v, --starting-line-number=NUMBER  first line number for each section", 10
    db "  -w, --number-width=NUMBER       use NUMBER columns for line numbers", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "Default options are: -bt -d'\:' -fn -hn -i1 -l1 -n'rn' -s<TAB> -v1 -w6", 10
    db 10
    db "CC are two delimiter characters used to construct logical page delimiters;", 10
    db "a missing second character implies ':'.  As a GNU extension one can specify", 10
    db "more than two characters, and also specifying the empty string (-d '')", 10
    db "disables section matching.", 10
    db 10
    db "STYLE is one of:", 10
    db 10
    db "  a      number all lines", 10
    db "  t      number only nonempty lines", 10
    db "  n      number no lines", 10
    db "  pBRE   number only lines that contain a match for the basic regular", 10
    db "         expression, BRE", 10
    db 10
    db "FORMAT is one of:", 10
    db 10
    db "  ln     left justified, no leading zeros", 10
    db "  rn     right justified, no leading zeros", 10
    db "  rz     right justified, leading zeros", 10
    db 10
help_text_len equ $ - help_text

version_text:
    db "nl (fcoreutils) 0.1.0", 10
version_text_len equ $ - version_text
; @@DATA_END@@

str_eperm:          db "Operation not permitted", 0
str_enoent:         db "No such file or directory", 0
str_eio:            db "Input/output error", 0
str_ebadf:          db "Bad file descriptor", 0
str_enomem:         db "Cannot allocate memory", 0
str_eacces:         db "Permission denied", 0
str_enotdir:        db "Not a directory", 0
str_eisdir:         db "Is a directory", 0
str_einval:         db "Invalid argument", 0
str_emfile:         db "Too many open files", 0
str_enametoolong:   db "File name too long", 0
str_eunknown:       db "Unknown error", 0

; ─── BSS Section ─────────────────────────────────────────
section .bss

; I/O buffers
read_buf:       resb READ_BUF_SIZE
out_buf:        resb OUT_BUF_SIZE
line_buf:       resb LINE_BUF_SIZE
line_buf_used:  resq 1

; Number formatting scratch
itoa_buf:       resb 32

; Prefix cache (pre-formatted number prefix for fast emit)
prefix_buf:     resb 64
prefix_valid:   resb 1
               resb 7              ; padding
prefix_total_len: resq 1
prefix_digit_start: resq 1
prefix_digit_end:   resq 1

; Separator string
separator:      resb MAX_SEP_LEN

; State variables
body_style:     resb 1
header_style:   resb 1
footer_style:   resb 1
num_format:     resb 1
no_renumber:    resb 1
cur_section:    resb 1
delim_char1:    resb 1
delim_char2:    resb 1
delim_len:      resb 1
is_default_opts: resb 1
pad_bss:        resb 6

line_number:    resq 1
line_incr:      resq 1
join_blank:     resq 1
start_num:      resq 1
num_width:      resq 1
sep_len:        resq 1
blank_count:    resq 1
num_files:      resd 1
argv_base:      resq 1
argv_count:     resq 1
arg_index:      resq 1
line_start:     resq 1
line_ptr:       resq 1
line_len:       resq 1
mmap_base:      resq 1
mmap_size:      resq 1
seen_dashdash:  resb 1
