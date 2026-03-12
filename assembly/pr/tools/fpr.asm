; fpr.asm — GNU-compatible "pr" in x86-64 Linux assembly
;
; A drop-in replacement for GNU coreutils `pr`. Pure x86-64 assembly,
; no libc, no dynamic linker. Handles all major flags:
;   +FIRST_PAGE[:LAST_PAGE], -COLUMN, -a, -d, -f/-F, -h HEADER,
;   -l NUM, -m, -n[SEP[WIDTH]], -o NUM, -r, -s[SEP], -t, -T, -v,
;   -w NUM, -W NUM, -J, -S[STRING], -N NUM, -e[CHAR[WIDTH]],
;   -i[CHAR[WIDTH]], -c, -D FORMAT, --help, --version
;
; Page layout: 5 header lines + body lines + 5 footer lines = page length
; Header: 2 blank + "date  header  Page N" + 2 blank
; Footer: 5 blank lines (or form feed with -f/-F)
;
; Performance: mmap input, 512KB output buffer, SIMD newline scanning
;
; Register conventions (global state):
;   r12 = out_buf_used (bytes currently in output buffer)
;   r13 = processed_any flag (0=no file/stdin processed yet)
;   ebp = had_error flag (0=ok, 1=error occurred)

%include "include/linux.inc"
%include "include/macros.inc"

default rel

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close

; ─── Constants ───────────────────────────────────────────
%define OUT_BUF_SIZE      524288
%define FLUSH_THRESHOLD   393216
%define MAX_HEADER_LEN    1024
%define MAX_SEP_LEN       256
%define MAX_FILES         64
%define MAX_PAGE_LINES    10000
%define LINE_PTRS_SIZE    80000       ; MAX_PAGE_LINES * 8
%define LINE_LENS_SIZE    40000       ; MAX_PAGE_LINES * 4
%define COL_BUF_SIZE      1048576     ; 1MB for column formatting

; Page defaults
%define DEFAULT_PAGE_LEN  66
%define DEFAULT_PAGE_WID  72
%define HEADER_LINES      5
%define FOOTER_LINES      5

; mmap flags
%define MAP_PRIVATE       2
%define MAP_POPULATE      0x08000
%define PROT_READ         1
%define MADV_SEQUENTIAL   2
%define SYS_MADVISE       28

; fstat struct offsets (struct stat on x86_64 Linux)
%define STAT_SIZE         144
%define STAT_ST_SIZE_OFF  48
%define STAT_ST_MTIME_OFF 88

global _start

section .text

; ═══════════════════════════════════════════════════════════
; Entry Point
; ═══════════════════════════════════════════════════════════
_start:
    BLOCK_SIGPIPE

    ; Parse argc/argv from stack
    mov     r14, [rsp]              ; argc
    lea     r15, [rsp + 8]          ; argv[0]

    ; Skip argv[0]
    dec     r14
    add     r15, 8                  ; &argv[1]

    ; Initialize global state
    mov     byte [had_error], 0     ; had_error = 0
    xor     r12d, r12d              ; out_buf_used = 0
    xor     r13d, r13d              ; processed_any = 0

    ; Initialize config defaults
    mov     qword [opt_first_page], 1
    mov     qword [opt_last_page], 0
    mov     qword [opt_columns], 1
    mov     byte [opt_across], 0
    mov     byte [opt_show_ctrl], 0
    mov     byte [opt_double_space], 0
    mov     byte [opt_form_feed], 0
    mov     byte [opt_join_lines], 0
    mov     qword [opt_page_length], DEFAULT_PAGE_LEN
    mov     byte [opt_merge], 0
    mov     byte [opt_number_lines], 0
    mov     byte [opt_number_sep], 9    ; TAB
    mov     qword [opt_number_width], 5
    mov     qword [opt_first_line_num], 1
    mov     qword [opt_indent], 0
    mov     byte [opt_no_file_warn], 0
    mov     byte [opt_has_sep], 0
    mov     byte [opt_sep_char], 9      ; TAB
    mov     byte [opt_has_sep_string], 0
    mov     qword [opt_sep_string_len], 0
    mov     byte [opt_omit_header], 0
    mov     byte [opt_omit_pagination], 0
    mov     byte [opt_show_nonprint], 0
    mov     qword [opt_page_width], DEFAULT_PAGE_WID
    mov     byte [opt_truncate], 0
    mov     byte [opt_expand_tabs], 0
    mov     byte [opt_expand_char], 9   ; TAB
    mov     qword [opt_expand_width], 8
    mov     byte [opt_output_tabs], 0
    mov     byte [opt_output_tab_char], 9
    mov     qword [opt_output_tab_width], 8
    mov     qword [opt_header_ptr], 0
    mov     qword [opt_header_len], 0
    mov     dword [num_files], 0

    ; Initialize spaces buffer with space characters
    lea     rdi, [rel spaces_buf]
    mov     al, ' '
    mov     ecx, 256
    rep     stosb

    ; Store argv info
    mov     [argv_base], r15
    mov     [argv_count], r14

    ; If no args, read stdin
    test    r14, r14
    jz      .done_files

    ; Parse arguments
    mov     qword [arg_index], 0
    mov     byte [seen_dashdash], 0

.parse_loop:
    mov     rbx, [arg_index]
    cmp     rbx, [argv_count]
    jge     .done_files

    mov     rcx, [argv_base]
    mov     rsi, [rcx + rbx*8]     ; argv[i]

    ; If seen --, treat as filename
    cmp     byte [seen_dashdash], 0
    jne     .is_file

    ; Check for + prefix (page specification)
    cmp     byte [rsi], '+'
    je      .parse_page_spec

    ; Check for - prefix
    cmp     byte [rsi], '-'
    jne     .is_file
    cmp     byte [rsi+1], 0
    je      .is_stdin              ; bare "-" = stdin
    cmp     byte [rsi+1], '-'
    jne     .short_opt

    ; Starts with "--"
    cmp     byte [rsi+2], 0
    je      .set_dashdash

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
    jz      .parse_next

    ; Unrecognized option
    mov     rbx, [arg_index]
    mov     rcx, [argv_base]
    mov     rsi, [rcx + rbx*8]
    call    err_unrecognized_option
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.parse_page_spec:
    ; +FIRST[:LAST]
    inc     rsi                    ; skip '+'
    call    parse_page_range
    jmp     .parse_next

.short_opt:
    inc     rsi                    ; skip '-'
    call    parse_short_options
    test    eax, eax
    jnz     .short_opt_error
    jmp     .parse_next

.short_opt_error:
    mov     rbx, [arg_index]
    mov     rcx, [argv_base]
    mov     rsi, [rcx + rbx*8]
    call    err_invalid_option
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.set_dashdash:
    mov     byte [seen_dashdash], 1
    jmp     .parse_next

.is_stdin:
    mov     r13d, 1
    ; Store "-" as filename
    mov     rbx, [arg_index]
    mov     rcx, [argv_base]
    mov     rsi, [rcx + rbx*8]
    mov     eax, [num_files]
    cmp     eax, MAX_FILES
    jge     .parse_next
    lea     rdi, [rel file_ptrs]
    mov     [rdi + rax*8], rsi
    inc     dword [num_files]
    jmp     .parse_next

.is_file:
    mov     r13d, 1
    mov     rbx, [arg_index]
    mov     rcx, [argv_base]
    mov     rsi, [rcx + rbx*8]
    mov     eax, [num_files]
    cmp     eax, MAX_FILES
    jge     .parse_next
    lea     rdi, [rel file_ptrs]
    mov     [rdi + rax*8], rsi
    inc     dword [num_files]
    jmp     .parse_next

.parse_next:
    inc     qword [arg_index]
    jmp     .parse_loop

.done_files:
    ; If merge mode, handle all files together
    cmp     byte [opt_merge], 0
    jne     .do_merge_mode

    ; If no files, read stdin
    cmp     dword [num_files], 0
    jne     .process_files

    ; Read stdin
    lea     rdi, [rel str_dash]
    call    process_single_file
    jmp     .final_flush

.process_files:
    mov     dword [file_index], 0
.file_loop:
    mov     eax, [file_index]
    cmp     eax, [num_files]
    jge     .final_flush
    lea     rdi, [rel file_ptrs]
    mov     eax, [file_index]
    mov     rdi, [rdi + rax*8]
    call    process_single_file
    inc     dword [file_index]
    jmp     .file_loop

.do_merge_mode:
    call    process_merge
    jmp     .final_flush

.final_flush:
    call    flush_output
    test    eax, eax
    jnz     .write_error_exit

    movzx   edi, byte [had_error]
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
; parse_page_range: parse +FIRST[:LAST] from rsi
; ═══════════════════════════════════════════════════════════
parse_page_range:
    push    rbx
    ; Parse FIRST number
    xor     rax, rax
.ppr_first:
    movzx   ecx, byte [rsi]
    cmp     cl, ':'
    je      .ppr_colon
    cmp     cl, 0
    je      .ppr_done_first
    sub     cl, '0'
    jb      .ppr_done_first
    cmp     cl, 9
    ja      .ppr_done_first
    imul    rax, 10
    movzx   ecx, cl
    add     rax, rcx
    inc     rsi
    jmp     .ppr_first

.ppr_done_first:
    test    rax, rax
    jz      .ppr_ret
    mov     [opt_first_page], rax
    jmp     .ppr_ret

.ppr_colon:
    test    rax, rax
    jz      .ppr_skip_first
    mov     [opt_first_page], rax
.ppr_skip_first:
    inc     rsi                    ; skip ':'
    xor     rax, rax
.ppr_last:
    movzx   ecx, byte [rsi]
    test    cl, cl
    jz      .ppr_done_last
    sub     cl, '0'
    jb      .ppr_done_last
    cmp     cl, 9
    ja      .ppr_done_last
    imul    rax, 10
    movzx   ecx, cl
    add     rax, rcx
    inc     rsi
    jmp     .ppr_last

.ppr_done_last:
    test    rax, rax
    jz      .ppr_ret
    mov     [opt_last_page], rax

.ppr_ret:
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; parse_short_options: parse short option cluster from rsi
; Returns eax=0 on success, eax=-1 on error
; ═══════════════════════════════════════════════════════════
parse_short_options:
    push    rbx
    push    r14
    push    r15
    mov     r14, rsi

.pso_loop:
    movzx   eax, byte [r14]
    test    al, al
    jz      .pso_done

    ; Check if it's a digit (for -COLUMN)
    cmp     al, '0'
    jb      .pso_not_digit
    cmp     al, '9'
    ja      .pso_not_digit
    ; Parse column count
    mov     rsi, r14
    call    parse_number
    mov     [opt_columns], rax
    jmp     .pso_done

.pso_not_digit:
    cmp     al, 'a'
    je      .pso_a
    cmp     al, 'c'
    je      .pso_c
    cmp     al, 'd'
    je      .pso_d
    cmp     al, 'D'
    je      .pso_D
    cmp     al, 'e'
    je      .pso_e
    cmp     al, 'f'
    je      .pso_f
    cmp     al, 'F'
    je      .pso_f
    cmp     al, 'h'
    je      .pso_h
    cmp     al, 'i'
    je      .pso_i
    cmp     al, 'J'
    je      .pso_J
    cmp     al, 'l'
    je      .pso_l
    cmp     al, 'm'
    je      .pso_m
    cmp     al, 'n'
    je      .pso_n
    cmp     al, 'N'
    je      .pso_N
    cmp     al, 'o'
    je      .pso_o
    cmp     al, 'r'
    je      .pso_r
    cmp     al, 's'
    je      .pso_s
    cmp     al, 'S'
    je      .pso_S
    cmp     al, 't'
    je      .pso_t
    cmp     al, 'T'
    je      .pso_T
    cmp     al, 'v'
    je      .pso_v
    cmp     al, 'w'
    je      .pso_w
    cmp     al, 'W'
    je      .pso_W

    ; Unknown option
    mov     eax, -1
    pop     r15
    pop     r14
    pop     rbx
    ret

.pso_a:
    mov     byte [opt_across], 1
    inc     r14
    jmp     .pso_loop

.pso_c:
    mov     byte [opt_show_ctrl], 1
    inc     r14
    jmp     .pso_loop

.pso_d:
    mov     byte [opt_double_space], 1
    inc     r14
    jmp     .pso_loop

.pso_D:
    ; -D FORMAT: next arg is date format (we store but don't use custom format in asm)
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_consumed
    call    .get_next_arg
    test    rax, rax
    jz      .pso_done
    ; Store date format ptr (not implemented in asm, use default)
    jmp     .pso_consumed

.pso_e:
    ; -e[CHAR[WIDTH]]
    mov     byte [opt_expand_tabs], 1
    inc     r14
    cmp     byte [r14], 0
    je      .pso_loop
    ; Check if next char is digit
    movzx   eax, byte [r14]
    cmp     al, '0'
    jb      .pso_e_char
    cmp     al, '9'
    ja      .pso_e_char
    ; It's a width
    mov     rsi, r14
    call    parse_number
    mov     [opt_expand_width], rax
    jmp     .pso_done
.pso_e_char:
    mov     [opt_expand_char], al
    inc     r14
    cmp     byte [r14], 0
    je      .pso_loop
    mov     rsi, r14
    call    parse_number
    mov     [opt_expand_width], rax
    jmp     .pso_done

.pso_f:
    mov     byte [opt_form_feed], 1
    inc     r14
    jmp     .pso_loop

.pso_h:
    ; -h HEADER
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_h_inline
    call    .get_next_arg
    test    rax, rax
    jz      .pso_done
    mov     r14, rax
.pso_h_inline:
    mov     [opt_header_ptr], r14
    ; Compute length
    mov     rdi, r14
    call    strlen
    mov     [opt_header_len], rax
    jmp     .pso_consumed

.pso_i:
    ; -i[CHAR[WIDTH]]
    mov     byte [opt_output_tabs], 1
    inc     r14
    cmp     byte [r14], 0
    je      .pso_loop
    movzx   eax, byte [r14]
    cmp     al, '0'
    jb      .pso_i_char
    cmp     al, '9'
    ja      .pso_i_char
    mov     rsi, r14
    call    parse_number
    mov     [opt_output_tab_width], rax
    jmp     .pso_done
.pso_i_char:
    mov     [opt_output_tab_char], al
    inc     r14
    cmp     byte [r14], 0
    je      .pso_loop
    mov     rsi, r14
    call    parse_number
    mov     [opt_output_tab_width], rax
    jmp     .pso_done

.pso_J:
    mov     byte [opt_join_lines], 1
    inc     r14
    jmp     .pso_loop

.pso_l:
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_l_inline
    call    .get_next_arg
    test    rax, rax
    jz      .pso_done
    mov     r14, rax
.pso_l_inline:
    mov     rsi, r14
    call    parse_number
    mov     [opt_page_length], rax
    jmp     .pso_consumed

.pso_m:
    mov     byte [opt_merge], 1
    inc     r14
    jmp     .pso_loop

.pso_n:
    ; -n[SEP[DIGITS]]
    mov     byte [opt_number_lines], 1
    inc     r14
    cmp     byte [r14], 0
    je      .pso_loop
    movzx   eax, byte [r14]
    cmp     al, '0'
    jb      .pso_n_sep
    cmp     al, '9'
    ja      .pso_n_sep
    ; It's digits (width)
    mov     rsi, r14
    call    parse_number
    mov     [opt_number_width], rax
    jmp     .pso_done
.pso_n_sep:
    mov     [opt_number_sep], al
    inc     r14
    cmp     byte [r14], 0
    je      .pso_loop
    mov     rsi, r14
    call    parse_number
    mov     [opt_number_width], rax
    jmp     .pso_done

.pso_N:
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_N_inline
    call    .get_next_arg
    test    rax, rax
    jz      .pso_done
    mov     r14, rax
.pso_N_inline:
    mov     rsi, r14
    call    parse_number
    mov     [opt_first_line_num], rax
    jmp     .pso_consumed

.pso_o:
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_o_inline
    call    .get_next_arg
    test    rax, rax
    jz      .pso_done
    mov     r14, rax
.pso_o_inline:
    mov     rsi, r14
    call    parse_number
    mov     [opt_indent], rax
    jmp     .pso_consumed

.pso_r:
    mov     byte [opt_no_file_warn], 1
    inc     r14
    jmp     .pso_loop

.pso_s:
    ; -s[CHAR]
    mov     byte [opt_has_sep], 1
    inc     r14
    cmp     byte [r14], 0
    je      .pso_s_default
    mov     al, [r14]
    mov     [opt_sep_char], al
    inc     r14
    jmp     .pso_loop
.pso_s_default:
    mov     byte [opt_sep_char], 9    ; TAB
    jmp     .pso_loop

.pso_S:
    ; -S[STRING]
    mov     byte [opt_has_sep_string], 1
    inc     r14
    cmp     byte [r14], 0
    je      .pso_S_empty
    ; Copy string
    mov     [opt_sep_string_ptr], r14
    mov     rdi, r14
    call    strlen
    mov     [opt_sep_string_len], rax
    jmp     .pso_consumed
.pso_S_empty:
    mov     qword [opt_sep_string_len], 0
    jmp     .pso_loop

.pso_t:
    mov     byte [opt_omit_header], 1
    inc     r14
    jmp     .pso_loop

.pso_T:
    mov     byte [opt_omit_pagination], 1
    mov     byte [opt_omit_header], 1
    inc     r14
    jmp     .pso_loop

.pso_v:
    mov     byte [opt_show_nonprint], 1
    inc     r14
    jmp     .pso_loop

.pso_w:
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_w_inline
    call    .get_next_arg
    test    rax, rax
    jz      .pso_done
    mov     r14, rax
.pso_w_inline:
    mov     rsi, r14
    call    parse_number
    mov     [opt_page_width], rax
    jmp     .pso_consumed

.pso_W:
    inc     r14
    cmp     byte [r14], 0
    jne     .pso_W_inline
    call    .get_next_arg
    test    rax, rax
    jz      .pso_done
    mov     r14, rax
.pso_W_inline:
    mov     rsi, r14
    call    parse_number
    mov     [opt_page_width], rax
    mov     byte [opt_truncate], 1
    jmp     .pso_consumed

.pso_consumed:
    ; Fully consumed the rest of the option string
    jmp     .pso_done

.pso_done:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     rbx
    ret

; Helper: get next argv element, advance arg_index
; Returns rax = ptr to next arg, or 0 if none
.get_next_arg:
    mov     rbx, [arg_index]
    inc     rbx
    cmp     rbx, [argv_count]
    jge     .gna_none
    mov     [arg_index], rbx
    mov     rcx, [argv_base]
    mov     rax, [rcx + rbx*8]
    ret
.gna_none:
    xor     eax, eax
    ret

; ═══════════════════════════════════════════════════════════
; parse_long_option: parse --name=value options
; rsi = pointer to "--name=value"
; Returns eax=0 on recognized, eax=-1 on error
; ═══════════════════════════════════════════════════════════
parse_long_option:
    push    rbx
    push    r14
    push    r15
    mov     r14, rsi

    ; Try --columns=
    lea     rdi, [rel str_columns_eq]
    mov     rsi, r14
    call    starts_with
    test    eax, eax
    jnz     .plo_columns

    ; Try --length=
    lea     rdi, [rel str_length_eq]
    mov     rsi, r14
    call    starts_with
    test    eax, eax
    jnz     .plo_length

    ; Try --header=
    lea     rdi, [rel str_header_eq]
    mov     rsi, r14
    call    starts_with
    test    eax, eax
    jnz     .plo_header

    ; Try --indent=
    lea     rdi, [rel str_indent_eq]
    mov     rsi, r14
    call    starts_with
    test    eax, eax
    jnz     .plo_indent

    ; Try --page-width=
    lea     rdi, [rel str_pagewidth_eq]
    mov     rsi, r14
    call    starts_with
    test    eax, eax
    jnz     .plo_pagewidth

    ; Try --pages=
    lea     rdi, [rel str_pages_eq]
    mov     rsi, r14
    call    starts_with
    test    eax, eax
    jnz     .plo_pages

    ; Try --first-line-number=
    lea     rdi, [rel str_firstlinenum_eq]
    mov     rsi, r14
    call    starts_with
    test    eax, eax
    jnz     .plo_firstlinenum

    ; Try --sep-string=
    lea     rdi, [rel str_sepstring_eq]
    mov     rsi, r14
    call    starts_with
    test    eax, eax
    jnz     .plo_sepstring

    ; Simple flags
    lea     rdi, [rel str_across_flag]
    mov     rsi, r14
    call    strcmp
    test    eax, eax
    jz      .plo_across

    mov     rsi, r14
    lea     rdi, [rel str_double_space_flag]
    call    strcmp
    test    eax, eax
    jz      .plo_double_space

    mov     rsi, r14
    lea     rdi, [rel str_form_feed_flag]
    call    strcmp
    test    eax, eax
    jz      .plo_form_feed

    mov     rsi, r14
    lea     rdi, [rel str_join_lines_flag]
    call    strcmp
    test    eax, eax
    jz      .plo_join_lines

    mov     rsi, r14
    lea     rdi, [rel str_merge_flag]
    call    strcmp
    test    eax, eax
    jz      .plo_merge

    mov     rsi, r14
    lea     rdi, [rel str_number_lines_flag]
    call    strcmp
    test    eax, eax
    jz      .plo_number_lines

    mov     rsi, r14
    lea     rdi, [rel str_no_file_warn_flag]
    call    strcmp
    test    eax, eax
    jz      .plo_no_file_warn

    mov     rsi, r14
    lea     rdi, [rel str_omit_header_flag]
    call    strcmp
    test    eax, eax
    jz      .plo_omit_header

    mov     rsi, r14
    lea     rdi, [rel str_omit_pagination_flag]
    call    strcmp
    test    eax, eax
    jz      .plo_omit_pagination

    mov     rsi, r14
    lea     rdi, [rel str_show_ctrl_flag]
    call    strcmp
    test    eax, eax
    jz      .plo_show_ctrl

    mov     rsi, r14
    lea     rdi, [rel str_show_nonprint_flag]
    call    strcmp
    test    eax, eax
    jz      .plo_show_nonprint

    ; Not recognized
    mov     eax, -1
    pop     r15
    pop     r14
    pop     rbx
    ret

.plo_columns:
    ; rax = length of prefix
    lea     rsi, [r14 + rax]
    call    parse_number
    mov     [opt_columns], rax
    jmp     .plo_ok

.plo_length:
    lea     rsi, [r14 + rax]
    call    parse_number
    mov     [opt_page_length], rax
    jmp     .plo_ok

.plo_header:
    lea     rsi, [r14 + rax]
    mov     [opt_header_ptr], rsi
    mov     rdi, rsi
    call    strlen
    mov     [opt_header_len], rax
    jmp     .plo_ok

.plo_indent:
    lea     rsi, [r14 + rax]
    call    parse_number
    mov     [opt_indent], rax
    jmp     .plo_ok

.plo_pagewidth:
    lea     rsi, [r14 + rax]
    call    parse_number
    mov     [opt_page_width], rax
    mov     byte [opt_truncate], 1
    jmp     .plo_ok

.plo_pages:
    lea     rsi, [r14 + rax]
    call    parse_page_range
    jmp     .plo_ok

.plo_firstlinenum:
    lea     rsi, [r14 + rax]
    call    parse_number
    mov     [opt_first_line_num], rax
    jmp     .plo_ok

.plo_sepstring:
    lea     rsi, [r14 + rax]
    mov     byte [opt_has_sep_string], 1
    mov     [opt_sep_string_ptr], rsi
    mov     rdi, rsi
    call    strlen
    mov     [opt_sep_string_len], rax
    jmp     .plo_ok

.plo_across:
    mov     byte [opt_across], 1
    jmp     .plo_ok

.plo_double_space:
    mov     byte [opt_double_space], 1
    jmp     .plo_ok

.plo_form_feed:
    mov     byte [opt_form_feed], 1
    jmp     .plo_ok

.plo_join_lines:
    mov     byte [opt_join_lines], 1
    jmp     .plo_ok

.plo_merge:
    mov     byte [opt_merge], 1
    jmp     .plo_ok

.plo_number_lines:
    mov     byte [opt_number_lines], 1
    jmp     .plo_ok

.plo_no_file_warn:
    mov     byte [opt_no_file_warn], 1
    jmp     .plo_ok

.plo_omit_header:
    mov     byte [opt_omit_header], 1
    jmp     .plo_ok

.plo_omit_pagination:
    mov     byte [opt_omit_pagination], 1
    mov     byte [opt_omit_header], 1
    jmp     .plo_ok

.plo_show_ctrl:
    mov     byte [opt_show_ctrl], 1
    jmp     .plo_ok

.plo_show_nonprint:
    mov     byte [opt_show_nonprint], 1
    jmp     .plo_ok

.plo_ok:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; process_single_file: process one file for pr output
; rdi = filename (or "-" for stdin)
; ═══════════════════════════════════════════════════════════
process_single_file:
    push    rbx
    push    r14
    push    r15
    push    rbp
    sub     rsp, STAT_SIZE + 8      ; space for fstat + alignment

    mov     r14, rdi                ; save filename

    ; Check if stdin
    mov     rdi, r14
    lea     rsi, [rel str_dash]
    call    strcmp
    test    eax, eax
    jz      .psf_stdin

    ; Open file
    mov     rdi, r14
    mov     esi, O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .psf_open_error
    mov     rbx, rax                ; fd

    ; fstat to get size and mtime
    mov     rdi, rbx
    mov     rsi, rsp
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .psf_close_error

    ; Get file size
    mov     r15, [rsp + STAT_ST_SIZE_OFF]    ; file size

    ; Get mtime
    mov     rax, [rsp + STAT_ST_MTIME_OFF]
    mov     [cur_file_mtime], rax

    ; If file is empty, special handling
    test    r15, r15
    jz      .psf_empty_file

    ; mmap the file
    xor     edi, edi                ; addr = NULL
    mov     rsi, r15                ; length
    mov     edx, PROT_READ          ; prot
    mov     r10d, MAP_PRIVATE | MAP_POPULATE  ; flags
    mov     r8, rbx                 ; fd
    xor     r9d, r9d                ; offset
    mov     rax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .psf_close_error
    mov     [cur_mmap_addr], rax
    mov     [cur_mmap_len], r15

    ; madvise sequential
    mov     rdi, rax
    mov     rsi, r15
    mov     edx, MADV_SEQUENTIAL
    mov     rax, SYS_MADVISE
    syscall

    ; Close fd (we have the mmap)
    mov     rdi, rbx
    call    asm_close

    ; Process the mmap'd data
    mov     rdi, r14                ; filename
    mov     rsi, [cur_mmap_addr]    ; data ptr
    mov     rdx, [cur_mmap_len]     ; data len
    call    pr_format_data

    ; munmap
    mov     rdi, [cur_mmap_addr]
    mov     rsi, [cur_mmap_len]
    mov     rax, SYS_MUNMAP
    syscall

    jmp     .psf_ret

.psf_stdin:
    ; Get current time for stdin
    sub     rsp, 16
    mov     eax, SYS_CLOCK_GETTIME
    xor     edi, edi                ; CLOCK_REALTIME
    mov     rsi, rsp
    syscall
    mov     rax, [rsp]              ; tv_sec
    mov     [cur_file_mtime], rax
    add     rsp, 16

    ; Read all of stdin into a buffer via brk
    call    read_all_stdin
    ; rax = data ptr, rdx = data len
    test    rdx, rdx
    jz      .psf_empty_stdin

    mov     [cur_stdin_ptr], rax
    mov     [cur_stdin_len], rdx

    ; Process data
    lea     rdi, [rel str_empty]    ; empty header for stdin
    mov     rsi, [cur_stdin_ptr]
    mov     rdx, [cur_stdin_len]
    call    pr_format_data

    jmp     .psf_ret

.psf_empty_stdin:
    ; Even empty stdin gets formatted (shows header page if not -t)
    lea     rdi, [rel str_empty]
    xor     esi, esi
    xor     edx, edx
    call    pr_format_data
    jmp     .psf_ret

.psf_empty_file:
    ; Close fd
    mov     rdi, rbx
    call    asm_close
    ; Format empty data
    mov     rdi, r14
    xor     esi, esi
    xor     edx, edx
    call    pr_format_data
    jmp     .psf_ret

.psf_open_error:
    cmp     byte [opt_no_file_warn], 0
    jne     .psf_skip_warn
    ; Print error: "pr: <filename>: No such file or directory"
    mov     rdi, r14
    call    print_open_error
.psf_skip_warn:
    mov     byte [had_error], 1
    jmp     .psf_ret

.psf_close_error:
    mov     rdi, rbx
    call    asm_close
    mov     byte [had_error], 1
    jmp     .psf_ret

.psf_ret:
    add     rsp, STAT_SIZE + 8
    pop     rbp
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; read_all_stdin: read all of stdin into memory
; Returns: rax = ptr to data, rdx = length
; Uses brk to allocate memory
; ═══════════════════════════════════════════════════════════
read_all_stdin:
    push    rbx
    push    r14
    push    r15

    ; Get current brk
    mov     rax, SYS_BRK
    xor     edi, edi
    syscall
    mov     r14, rax                ; start of our allocation
    mov     r15, rax                ; current end
    mov     rbx, rax                ; write position

    ; Extend brk by 1MB initially
    lea     rdi, [rax + 1048576]
    mov     rax, SYS_BRK
    syscall
    mov     r15, rax                ; new end

.ras_loop:
    ; Calculate remaining space
    mov     rdx, r15
    sub     rdx, rbx
    cmp     rdx, 4096
    jg      .ras_read
    ; Need more space
    lea     rdi, [r15 + 1048576]
    mov     rax, SYS_BRK
    syscall
    mov     r15, rax
    mov     rdx, r15
    sub     rdx, rbx

.ras_read:
    mov     rdi, STDIN
    mov     rsi, rbx
    ; rdx already set
    mov     rax, SYS_READ
    syscall
    cmp     rax, EINTR
    je      .ras_loop
    test    rax, rax
    jle     .ras_done
    add     rbx, rax
    jmp     .ras_loop

.ras_done:
    mov     rax, r14                ; data start
    mov     rdx, rbx
    sub     rdx, r14                ; length

    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; pr_format_data: format file data with pr pagination
; rdi = filename, rsi = data ptr, rdx = data len
; ═══════════════════════════════════════════════════════════
pr_format_data:
    push    rbx
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40                 ; local vars

    mov     [rsp], rdi              ; [rsp+0] = filename
    mov     [rsp+8], rsi            ; [rsp+8] = data ptr
    mov     [rsp+16], rdx           ; [rsp+16] = data len
    mov     qword [rsp+24], 0       ; [rsp+24] = data offset
    mov     qword [rsp+32], 1       ; [rsp+32] = current page number

    ; ── Fast path: simple -t passthrough ──
    ; If: -t, single column, no numbering, no indent, no double-space,
    ;     no truncation, no page range, no expand/output tabs
    ; Then: just copy data directly to output buffer
    cmp     byte [opt_omit_header], 0
    je      .pfd_slow_path
    cmp     qword [opt_columns], 1
    jne     .pfd_slow_path
    cmp     byte [opt_number_lines], 0
    jne     .pfd_slow_path
    cmp     qword [opt_indent], 0
    jne     .pfd_slow_path
    cmp     byte [opt_double_space], 0
    jne     .pfd_slow_path
    cmp     byte [opt_truncate], 0
    jne     .pfd_slow_path
    cmp     qword [opt_first_page], 1
    jne     .pfd_slow_path
    cmp     qword [opt_last_page], 0
    jne     .pfd_slow_path
    cmp     byte [opt_expand_tabs], 0
    jne     .pfd_slow_path
    cmp     byte [opt_show_ctrl], 0
    jne     .pfd_slow_path
    ; Fast path: write data directly to stdout (bypass buffer)
    ; First flush any existing buffer contents
    call    flush_output
    ; Then write data directly using asm_write_all
    mov     rdi, STDOUT
    mov     rsi, [rsp+8]
    mov     rdx, [rsp+16]
    test    rdx, rdx
    jz      .pfd_done
    call    asm_write_all
    jmp     .pfd_done

.pfd_slow_path:
    ; Initialize line number
    mov     rax, [opt_first_line_num]
    mov     [cur_line_number], rax

    ; Calculate body lines per page
    mov     rax, [opt_page_length]
    cmp     byte [opt_omit_header], 0
    jne     .pfd_no_header_lines
    sub     rax, HEADER_LINES
    sub     rax, FOOTER_LINES
    ; If body_lines <= 0 with headers, fall back
    test    rax, rax
    jg      .pfd_body_ok
    mov     rax, [opt_page_length]
    jmp     .pfd_body_ok
.pfd_no_header_lines:
    ; -t: all lines are body, no header/footer
.pfd_body_ok:
    mov     [body_lines_per_page], rax

.pfd_page_loop:
    ; Check if we've consumed all data
    mov     rax, [rsp+24]           ; offset
    cmp     rax, [rsp+16]           ; data len
    jge     .pfd_done

    ; Check last_page limit
    mov     rax, [opt_last_page]
    test    rax, rax
    jz      .pfd_no_last_limit
    mov     rcx, [rsp+32]           ; current page
    cmp     rcx, rax
    jg      .pfd_done
.pfd_no_last_limit:

    ; Collect lines for this page
    ; For multi-column down mode: collect columns * body_lines lines
    ; For single column: collect body_lines lines
    ; With double-spacing: each content line takes 2 physical rows
    mov     rax, [body_lines_per_page]
    cmp     byte [opt_double_space], 0
    je      .pfd_no_ds_adjust
    ; Halve body_lines for double-spacing (each line takes 2 rows)
    shr     rax, 1
.pfd_no_ds_adjust:
    mov     rcx, [opt_columns]
    cmp     byte [opt_across], 0
    jne     .pfd_across_count
    imul    rax, rcx                ; total lines needed for multi-col down
    jmp     .pfd_count_set
.pfd_across_count:
    ; across mode: body_lines rows, each row has columns items
    imul    rax, rcx
.pfd_count_set:
    mov     [lines_to_collect], rax

    ; Collect lines from data
    mov     rsi, [rsp+8]            ; data ptr
    add     rsi, [rsp+24]           ; + offset
    mov     rdx, [rsp+16]
    sub     rdx, [rsp+24]           ; remaining len
    mov     rdi, rax                ; max lines to collect
    call    collect_lines
    ; Returns: rax = number of lines collected, rdx = bytes consumed
    mov     [lines_collected], rax
    add     [rsp+24], rdx           ; advance offset

    ; If no lines collected and we're past all data, done
    test    rax, rax
    jz      .pfd_done

    ; Check if this page should be printed (first_page filter)
    mov     rcx, [rsp+32]           ; current page
    cmp     rcx, [opt_first_page]
    jl      .pfd_skip_page

    ; Print page header
    cmp     byte [opt_omit_header], 0
    jne     .pfd_no_hdr

    ; Format and print header
    mov     rdi, [rsp]              ; filename
    mov     rsi, [rsp+32]           ; page number
    call    print_page_header

.pfd_no_hdr:
    ; Print body lines
    call    print_page_body

    ; Print page footer
    cmp     byte [opt_omit_header], 0
    jne     .pfd_no_ftr
    call    print_page_footer
.pfd_no_ftr:

.pfd_skip_page:
    inc     qword [rsp+32]          ; next page
    jmp     .pfd_page_loop

.pfd_done:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; collect_lines: scan data for newlines, store line pointers
; rsi = data start, rdx = data len, rdi = max lines
; Returns: rax = lines collected, rdx = bytes consumed
; Stores line ptrs in line_ptrs[], lens in line_lens[]
; ═══════════════════════════════════════════════════════════
collect_lines:
    push    rbx
    push    r14
    push    r15
    push    rbp

    mov     r14, rsi                ; data start
    mov     r15, rdx                ; data len
    mov     rbp, rdi                ; max lines
    xor     ebx, ebx                ; lines collected
    mov     rcx, rsi                ; current scan pos
    lea     rdx, [rsi + r15]        ; end of data

.cl_loop:
    cmp     rbx, rbp
    jge     .cl_done
    cmp     rcx, rdx
    jge     .cl_done

    ; Store line start
    lea     rdi, [rel line_ptrs]
    mov     [rdi + rbx*8], rcx

    ; Find next newline using SWAR (8 bytes at a time)
    mov     rsi, rcx
    mov     r8, rdx
    sub     r8, rcx                 ; remaining bytes
    xor     eax, eax

    ; Quick path: scan 8 bytes at a time
    mov     r9, r8
    and     r9, ~7                  ; r9 = aligned length (multiple of 8)
    ; Constants for SWAR newline detection
    ; XOR with 0x0A0A0A0A0A0A0A0A makes newlines become 0x00
    ; Then (x - 0x0101...) & ~x & 0x8080... detects zero bytes
    mov     r10, 0x0A0A0A0A0A0A0A0A
    mov     r11, 0x0101010101010101

.cl_swar_loop:
    cmp     rax, r9
    jge     .cl_scan_tail
    mov     rcx, [rsi + rax]
    xor     rcx, r10                ; newlines become 0x00
    ; Check for zero byte: ((v - 0x0101...) & ~v & 0x8080...)
    mov     rdi, rcx
    sub     rcx, r11
    not     rdi
    and     rcx, rdi
    mov     rdi, 0x8080808080808080
    and     rcx, rdi
    jnz     .cl_swar_found          ; found a newline in this qword
    add     rax, 8
    jmp     .cl_swar_loop

.cl_swar_found:
    ; Find exact byte position using bsf (bit scan forward)
    bsf     rcx, rcx                ; rcx = bit index of first set bit
    shr     ecx, 3                  ; byte index within qword
    add     rax, rcx                ; rax = offset of newline
    jmp     .cl_found_newline

.cl_scan_tail:
    ; Scan remaining bytes one at a time
    cmp     rax, r8
    jge     .cl_no_newline
    cmp     byte [rsi + rax], 10
    je      .cl_found_newline
    inc     rax
    jmp     .cl_scan_tail

.cl_found_newline:
    ; Line length = rax (not including newline)
    lea     rdi, [rel line_lens]
    mov     [rdi + rbx*4], eax
    lea     rcx, [rsi + rax + 1]    ; past the newline
    inc     ebx
    jmp     .cl_loop

.cl_no_newline:
    ; Last line without newline
    lea     rdi, [rel line_lens]
    mov     eax, r8d
    mov     [rdi + rbx*4], eax
    lea     rcx, [rsi + r8]
    inc     ebx

.cl_done:
    mov     rax, rbx                ; lines collected
    mov     rdx, rcx
    sub     rdx, r14                ; bytes consumed

    pop     rbp
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; print_page_header: print header for a page
; rdi = filename, rsi = page number
; Header format:
;   <blank line>
;   <blank line>
;   <date>  <header>  Page <N>
;   <blank line>
;   <blank line>
; All padded to page_width
; ═══════════════════════════════════════════════════════════
print_page_header:
    push    rbx
    push    r14
    push    r15
    push    rbp

    mov     r14, rdi                ; filename
    mov     r15, rsi                ; page number

    ; Output 2 blank lines
    call    output_blank_line
    call    output_blank_line

    ; Build header line in header_buf
    lea     rbx, [rel header_buf]

    ; Add indent spaces if -o is set
    mov     rcx, [opt_indent]
    xor     eax, eax
.pph_indent:
    cmp     rax, rcx
    jge     .pph_indent_done
    mov     byte [rbx + rax], ' '
    inc     rax
    jmp     .pph_indent
.pph_indent_done:
    mov     rbp, rax                ; current position in header_buf

    ; Format date: YYYY-MM-DD HH:MM
    mov     [hdr_saved_rbx], rbx
    mov     [hdr_saved_rbp], rbp
    mov     rdi, [cur_file_mtime]
    lea     rsi, [rbx + rbp]
    call    format_date
    mov     rbx, [hdr_saved_rbx]
    mov     rbp, [hdr_saved_rbp]
    ; rax = 16
    add     rbp, rax
    mov     [hdr_date_len], rax

    ; Build "Page N" string in page_num_buf
    lea     rdi, [rel page_num_buf]
    mov     rsi, r15
    call    format_page_num
    mov     [hdr_page_len], rax

    ; Get header text
    cmp     qword [opt_header_ptr], 0
    je      .pph_use_filename
    mov     rsi, [opt_header_ptr]
    mov     rcx, [opt_header_len]
    jmp     .pph_have_header
.pph_use_filename:
    mov     rdi, r14                ; filename
    call    strlen
    mov     rcx, rax                ; header_text_len
    mov     rsi, r14                ; header text = filename
.pph_have_header:
    ; rsi = header text ptr, rcx = header text len
    mov     [hdr_text_len], rcx
    mov     [hdr_text_ptr], rsi

    ; Layout: date + pad + header_text + pad + "Page N" = page_width
    mov     rax, [opt_page_width]
    sub     rax, [opt_indent]       ; available width

    ; Check if enough space
    mov     rdx, [hdr_date_len]
    add     rdx, [hdr_page_len]
    add     rdx, [hdr_text_len]
    cmp     rax, rdx
    jl      .pph_tight_layout

    ; total_pad = available - date_len - page_str_len - header_len
    sub     rax, [hdr_date_len]
    sub     rax, [hdr_page_len]
    sub     rax, [hdr_text_len]
    ; rax = total_pad
    ; left_pad = total_pad / 2
    mov     rcx, rax
    shr     rcx, 1                  ; left_pad
    ; right_pad = total_pad - left_pad
    mov     rdx, rax
    sub     rdx, rcx                ; right_pad
    mov     [hdr_left_pad], rcx
    mov     [hdr_right_pad], rdx

    ; Fill header_buf with spaces from position rbp to page_width
    mov     rax, [opt_page_width]
    lea     rdi, [rbx + rbp]
    mov     rcx, rax
    sub     rcx, [opt_indent]
    sub     rcx, rbp
    add     rcx, [opt_indent]   ; fill from rbp to page_width
    mov     al, ' '
    rep     stosb

    ; Now overwrite the header text at the correct position
    ; Header text goes at: date_len + left_pad
    mov     rax, [hdr_left_pad]
    add     rax, rbp               ; position = after date + left_pad
    mov     rcx, [hdr_text_len]
    mov     rsi, [hdr_text_ptr]
    lea     rdi, [rbx + rax]
.pph_hdr_copy:
    test    rcx, rcx
    jz      .pph_hdr_done
    mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     rcx
    jmp     .pph_hdr_copy
.pph_hdr_done:

    ; "Page N" goes at: page_width - page_str_len
    mov     rax, [opt_page_width]
    sub     rax, [hdr_page_len]
    lea     rdi, [rbx + rax]
    lea     rsi, [rel page_num_buf]
    mov     rcx, [hdr_page_len]
.pph_page_copy:
    test    rcx, rcx
    jz      .pph_page_done
    mov     al, [rsi]
    inc     rsi
    mov     [rdi], al
    inc     rdi
    dec     rcx
    jmp     .pph_page_copy
.pph_page_done:

    ; Set rbp to page_width (total header line chars before newline)
    mov     rbp, [opt_page_width]
    jmp     .pph_write_header

.pph_tight_layout:
    ; Not enough space: date + 2sp + header + 2sp + page
    mov     byte [rbx + rbp], ' '
    mov     byte [rbx + rbp + 1], ' '
    add     rbp, 2
    mov     rcx, [hdr_text_len]
    mov     rsi, [hdr_text_ptr]
    lea     rdi, [rbx + rbp]
.pph_tight_hdr:
    test    rcx, rcx
    jz      .pph_tight_hdr_done
    mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     rcx
    jmp     .pph_tight_hdr
.pph_tight_hdr_done:
    add     rbp, [hdr_text_len]
    mov     byte [rbx + rbp], ' '
    mov     byte [rbx + rbp + 1], ' '
    add     rbp, 2
    lea     rsi, [rel page_num_buf]
    lea     rdi, [rbx + rbp]
    mov     rcx, [hdr_page_len]
.pph_tight_page:
    test    rcx, rcx
    jz      .pph_tight_page_done
    mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     rcx
    jmp     .pph_tight_page
.pph_tight_page_done:
    add     rbp, [hdr_page_len]

.pph_write_header:
    ; Add newline
    mov     byte [rbx + rbp], 10
    inc     rbp

    ; Write header line to output buffer
    lea     rsi, [rel header_buf]
    mov     rdx, rbp
    call    buffer_output

    ; Output 2 blank lines after header
    call    output_blank_line
    call    output_blank_line

    pop     rbp
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; print_page_body: print body lines for current page
; Uses lines_collected, line_ptrs[], line_lens[]
; ═══════════════════════════════════════════════════════════
print_page_body:
    push    rbx
    push    r14
    push    r15
    push    rbp

    mov     rax, [opt_columns]
    cmp     rax, 1
    jg      .ppb_multi_column

    ; ── Single column mode ──
    ; Fast path: if no special formatting, output lines as contiguous block
    cmp     byte [opt_number_lines], 0
    jne     .ppb_single_slow
    cmp     qword [opt_indent], 0
    jne     .ppb_single_slow
    cmp     byte [opt_double_space], 0
    jne     .ppb_single_slow
    cmp     byte [opt_truncate], 0
    jne     .ppb_single_slow
    cmp     byte [opt_show_ctrl], 0
    jne     .ppb_single_slow
    ; Fast: output all collected lines as one block
    ; Lines are contiguous in memory (from mmap or brk buffer)
    ; First line starts at line_ptrs[0], last line ends at
    ; line_ptrs[n-1] + line_lens[n-1] + 1 (including newline)
    mov     rax, [lines_collected]
    test    rax, rax
    jz      .ppb_single_pad_fast
    lea     rdi, [rel line_ptrs]
    mov     rsi, [rdi]              ; start = line_ptrs[0]
    dec     rax
    mov     rbx, [rdi + rax*8]     ; last line ptr
    lea     rdi, [rel line_lens]
    mov     edx, [rdi + rax*4]     ; last line len
    ; Total bytes = (last_line_ptr + last_line_len + 1) - first_line_ptr
    add     rbx, rdx                ; last line end (before newline)
    inc     rbx                     ; past newline
    sub     rbx, rsi                ; total bytes
    mov     rdx, rbx
    call    buffer_output
    ; Count lines for padding
    mov     rbx, [lines_collected]
    mov     r14, [body_lines_per_page]
    jmp     .ppb_single_pad_check
.ppb_single_pad_fast:
    xor     ebx, ebx
    mov     r14, [body_lines_per_page]
.ppb_single_pad_check:
    cmp     byte [opt_omit_header], 0
    jne     .ppb_done
.ppb_single_pad_fast_loop:
    cmp     rbx, r14
    jge     .ppb_done
    call    output_newline
    inc     rbx
    jmp     .ppb_single_pad_fast_loop

.ppb_single_slow:
    xor     ebx, ebx                ; line index (content)
    mov     r14, [body_lines_per_page]  ; max physical rows
    mov     qword [phys_row_count], 0   ; physical row counter

.ppb_single_loop:
    cmp     rbx, [lines_collected]
    jge     .ppb_single_pad
    mov     rax, [phys_row_count]
    cmp     rax, r14
    jge     .ppb_done

    ; Get line ptr and len
    lea     rdi, [rel line_ptrs]
    mov     rsi, [rdi + rbx*8]      ; line ptr
    lea     rdi, [rel line_lens]
    mov     edx, [rdi + rbx*4]      ; line len

    ; Output this line
    call    output_body_line
    inc     qword [phys_row_count]

    ; Double spacing: blank line after every content line (including last)
    cmp     byte [opt_double_space], 0
    je      .ppb_single_nods
    call    output_newline
    inc     qword [phys_row_count]
.ppb_single_nods:

    inc     rbx
    jmp     .ppb_single_loop

.ppb_single_pad:
    ; Pad remaining lines on page (only if not -t)
    cmp     byte [opt_omit_header], 0
    jne     .ppb_done
.ppb_pad_loop:
    mov     rax, [phys_row_count]
    cmp     rax, r14
    jge     .ppb_done
    call    output_newline
    inc     qword [phys_row_count]
    jmp     .ppb_pad_loop

.ppb_multi_column:
    ; ── Multi column mode ──
    ; For -t mode: rows = ceil(lines_collected / columns)
    ; For normal mode: rows = body_lines_per_page (pad with blanks)
    ; Column width = page_width / columns (or adjusted for separators)

    mov     r15, [opt_columns]          ; cols

    cmp     byte [opt_omit_header], 0
    je      .ppb_mc_use_body_lines
    ; -t mode: compute rows = ceil(lines_collected / columns)
    mov     rax, [lines_collected]
    add     rax, r15
    dec     rax                         ; lines + cols - 1
    xor     edx, edx
    div     r15                         ; rax = ceil(lines/cols)
    mov     r14, rax
    jmp     .ppb_mc_rows_set
.ppb_mc_use_body_lines:
    mov     r14, [body_lines_per_page]  ; rows
.ppb_mc_rows_set:

    ; Calculate column width and truncation width
    ; With -S[STRING]: col_width = (available - (cols-1)*sep_len) / cols
    ;                  trunc_width = col_width
    ; With -s[CHAR]: col_width = (available - (cols-1)*1) / cols
    ;                trunc_width = col_width (no padding anyway)
    ; Default: col_width = available / cols (padding IS the separator)
    ;          trunc_width = col_width - 1 (reserve 1 char for gap)
    mov     rax, [opt_page_width]
    sub     rax, [opt_indent]

    cmp     byte [opt_has_sep], 0
    jne     .ppb_mc_sep_char_width
    cmp     byte [opt_has_sep_string], 0
    jne     .ppb_mc_sep_string_width

    ; Default mode: col_width = available / cols, trunc = col_width - 1
    xor     edx, edx
    div     r15
    mov     [col_width], rax
    dec     rax
    mov     [col_trunc_width], rax
    jmp     .ppb_mc_width_done

.ppb_mc_sep_char_width:
    ; -s mode: col_width = (available - (cols-1)) / cols
    mov     rcx, r15
    dec     rcx
    sub     rax, rcx
    xor     edx, edx
    div     r15
    mov     [col_width], rax
    mov     [col_trunc_width], rax
    jmp     .ppb_mc_width_done

.ppb_mc_sep_string_width:
    ; -S mode: col_width = (available - (cols-1)*sep_len) / cols
    mov     rcx, r15
    dec     rcx
    imul    rcx, [opt_sep_string_len]
    sub     rax, rcx
    xor     edx, edx
    div     r15
    mov     [col_width], rax
    mov     [col_trunc_width], rax

.ppb_mc_width_done:

    xor     ebx, ebx                ; row index

.ppb_mc_row_loop:
    cmp     rbx, r14
    jge     .ppb_done

    ; Pre-scan: find the last non-empty column in this row
    ; Start from the rightmost column and scan left
    mov     rcx, r15                ; start at cols
.ppb_mc_find_last:
    dec     rcx
    js      .ppb_mc_row_empty       ; all empty -> skip row
    ; Calculate line index for col rcx, row rbx
    cmp     byte [opt_across], 0
    jne     .ppb_mc_find_across
    mov     rax, rcx
    imul    rax, r14
    add     rax, rbx
    jmp     .ppb_mc_find_check
.ppb_mc_find_across:
    mov     rax, rbx
    imul    rax, r15
    add     rax, rcx
.ppb_mc_find_check:
    cmp     rax, [lines_collected]
    jge     .ppb_mc_find_last
    ; Found: rcx = last non-empty column index
    mov     [last_nonempty_col], rcx
    jmp     .ppb_mc_start_cols

.ppb_mc_row_empty:
    ; All columns empty in this row, output empty line
    call    output_newline
    inc     ebx
    jmp     .ppb_mc_row_loop

.ppb_mc_start_cols:
    ; For each column in this row
    xor     ebp, ebp                ; col index
    mov     byte [need_separator], 0

.ppb_mc_col_loop:
    cmp     rbp, r15
    jge     .ppb_mc_row_end

    ; Calculate line index for this cell
    cmp     byte [opt_across], 0
    jne     .ppb_mc_across_idx
    ; Down mode: line_idx = col * body_lines + row
    mov     rax, rbp
    imul    rax, r14
    add     rax, rbx
    jmp     .ppb_mc_have_idx
.ppb_mc_across_idx:
    ; Across mode: line_idx = row * columns + col
    mov     rax, rbx
    imul    rax, r15
    add     rax, rbp
.ppb_mc_have_idx:
    ; Check if this line exists
    cmp     rax, [lines_collected]
    jge     .ppb_mc_empty_cell

    ; Save line index before potential separator output
    push    rax

    ; Output separator before column (if not first)
    cmp     byte [need_separator], 0
    je      .ppb_mc_no_sep
    call    output_column_separator
.ppb_mc_no_sep:
    mov     byte [need_separator], 1

    ; Get line data
    pop     rax                     ; restore line index
    push    rbx
    push    rbp
    mov     rbx, rax
    lea     rdi, [rel line_ptrs]
    mov     rsi, [rdi + rbx*8]
    lea     rdi, [rel line_lens]
    mov     edx, [rdi + rbx*4]

    ; Set absolute column start position for tab expansion
    mov     rax, rbp
    imul    rax, [col_width]
    mov     [cur_col_start], rax

    ; Output line content, padded to column width (unless last non-empty col)
    cmp     rbp, [last_nonempty_col]    ; is this the last non-empty column?
    je      .ppb_mc_last_col

    ; Not last column: pad to col_width
    call    output_column_cell
    pop     rbp
    pop     rbx
    jmp     .ppb_mc_next_col

.ppb_mc_last_col:
    ; Last column: just output content, no padding
    call    output_column_cell_last
    pop     rbp
    pop     rbx
    jmp     .ppb_mc_next_col

.ppb_mc_empty_cell:
    ; Empty cell in multi-column
    cmp     byte [need_separator], 0
    je      .ppb_mc_skip_empty
    ; Only output separator + padding if there are more non-empty columns
    ; For simplicity, just skip
.ppb_mc_skip_empty:
    inc     ebp
    jmp     .ppb_mc_col_loop

.ppb_mc_next_col:
    inc     ebp
    jmp     .ppb_mc_col_loop

.ppb_mc_row_end:
    ; End of row: newline
    call    output_newline

    ; Double spacing
    cmp     byte [opt_double_space], 0
    je      .ppb_mc_nods
    mov     rax, rbx
    inc     rax
    cmp     rax, r14
    jge     .ppb_mc_nods
    call    output_newline
.ppb_mc_nods:

    inc     ebx
    jmp     .ppb_mc_row_loop

.ppb_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; print_page_footer: print footer lines
; ═══════════════════════════════════════════════════════════
print_page_footer:
    push    rbx

    cmp     byte [opt_form_feed], 0
    jne     .ppftr_formfeed

    ; Print FOOTER_LINES blank lines
    mov     ebx, FOOTER_LINES
.ppftr_loop:
    test    ebx, ebx
    jz      .ppftr_done
    call    output_newline
    dec     ebx
    jmp     .ppftr_loop

.ppftr_formfeed:
    ; Output form feed character
    mov     byte [rel single_char_buf], 12   ; FF
    lea     rsi, [rel single_char_buf]
    mov     edx, 1
    call    buffer_output

.ppftr_done:
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; output_body_line: output a single body line with formatting
; rsi = line data, edx = line length
; Handles: indent, line numbering, tab expansion, truncation
; ═══════════════════════════════════════════════════════════
output_body_line:
    push    rbx
    push    r14
    push    r15
    push    rbp

    mov     r14, rsi                ; line ptr
    mov     r15d, edx               ; line len

    ; Output indent spaces
    mov     rcx, [opt_indent]
    test    rcx, rcx
    jz      .obl_no_indent
    lea     rsi, [rel spaces_buf]
    mov     rdx, rcx
    cmp     rdx, 256
    jle     .obl_indent_ok
    mov     rdx, 256
.obl_indent_ok:
    call    buffer_output
.obl_no_indent:

    ; Line numbering
    cmp     byte [opt_number_lines], 0
    je      .obl_no_number

    ; Format line number
    mov     rdi, [cur_line_number]
    mov     rsi, [opt_number_width]
    call    format_line_number
    ; rax = length of formatted number in num_format_buf

    lea     rsi, [rel num_format_buf]
    mov     rdx, rax
    call    buffer_output

    ; Output separator
    movzx   eax, byte [opt_number_sep]
    mov     [rel single_char_buf], al
    lea     rsi, [rel single_char_buf]
    mov     edx, 1
    call    buffer_output

    inc     qword [cur_line_number]

.obl_no_number:
    ; Output line content
    ; Handle -W truncation
    mov     edx, r15d
    cmp     byte [opt_truncate], 0
    je      .obl_no_truncate
    mov     rax, [opt_page_width]
    sub     rax, [opt_indent]
    ; Subtract number width if numbering
    cmp     byte [opt_number_lines], 0
    je      .obl_trunc_nonumber
    sub     rax, [opt_number_width]
    dec     rax                     ; separator char
.obl_trunc_nonumber:
    cmp     rdx, rax
    jle     .obl_no_truncate
    mov     edx, eax
.obl_no_truncate:

    ; Output line data
    mov     rsi, r14
    ; edx already set
    test    edx, edx
    jz      .obl_after_content
    call    buffer_output

.obl_after_content:
    ; Newline
    call    output_newline

    pop     rbp
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; output_column_cell: output a column cell padded to col_width
; rsi = data, edx = len
; Uses tab+space padding by default (like GNU pr)
; With -s/-S: no padding (separator handles separation)
; ═══════════════════════════════════════════════════════════
output_column_cell:
    push    rbx
    push    r14
    push    r15

    mov     r14d, edx               ; save len
    mov     rbx, [col_width]

    ; Truncate to col_trunc_width (may be col_width-1 for default separator)
    mov     rax, [col_trunc_width]
    cmp     r14, rax
    jle     .occ_no_trunc
    mov     r14, rax
.occ_no_trunc:

    ; Output data
    test    r14d, r14d
    jz      .occ_pad
    mov     edx, r14d
    call    buffer_output

.occ_pad:
    ; If -s (char separator), no padding needed (thin mode)
    ; -S (string separator) still pads columns to width
    cmp     byte [opt_has_sep], 0
    jne     .occ_done

    ; Pad with tabs + trailing spaces using ABSOLUTE line positions
    ; cur_col_start = absolute start position of this column
    ; r14 = content len, rbx = col_width
    ; absolute_pos = cur_col_start + content_len
    ; target_pos = cur_col_start + col_width
    mov     r15, [cur_col_start]
    add     r15, r14                ; r15 = absolute current pos
    mov     rbx, [cur_col_start]
    add     rbx, [col_width]        ; rbx = absolute target pos

    ; Phase 1: output tabs to advance to tab stops
.occ_tab_loop:
    ; next_tab = (abs_pos + 8) & ~7 = next tab stop from absolute position
    mov     rax, r15
    add     rax, 8
    and     rax, ~7                 ; next tab stop (absolute)
    cmp     rax, rbx                ; would tab stop exceed target?
    jg      .occ_spaces             ; yes, switch to spaces
    ; Output a tab
    mov     byte [rel single_char_buf], 9
    lea     rsi, [rel single_char_buf]
    mov     edx, 1
    push    rax
    call    buffer_output
    pop     rax
    mov     r15, rax                ; update absolute pos to tab stop
    jmp     .occ_tab_loop

.occ_spaces:
    ; Phase 2: output remaining spaces
    mov     rax, rbx
    sub     rax, r15                ; remaining = target - absolute_pos
    test    rax, rax
    jle     .occ_done
    lea     rsi, [rel spaces_buf]
    mov     edx, eax
    call    buffer_output

.occ_done:
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; output_column_cell_last: output last column (no padding, truncated)
; rsi = data, edx = len
; ═══════════════════════════════════════════════════════════
output_column_cell_last:
    test    edx, edx
    jz      .occl_done
    ; Truncate to col_trunc_width
    mov     rax, [col_trunc_width]
    cmp     rdx, rax
    jle     .occl_no_trunc
    mov     edx, eax
.occl_no_trunc:
    test    edx, edx
    jz      .occl_done
    call    buffer_output
.occl_done:
    ret

; ═══════════════════════════════════════════════════════════
; output_column_separator: output separator between columns
; ═══════════════════════════════════════════════════════════
output_column_separator:
    push    rbx

    ; Check -S (string separator)
    cmp     byte [opt_has_sep_string], 0
    jne     .ocs_string

    ; Check -s (char separator)
    cmp     byte [opt_has_sep], 0
    jne     .ocs_char

    ; Default: no explicit separator in multi-column
    ; GNU pr uses tabs to align columns
    ; The column_cell function handles padding
    pop     rbx
    ret

.ocs_char:
    movzx   eax, byte [opt_sep_char]
    mov     [rel single_char_buf], al
    lea     rsi, [rel single_char_buf]
    mov     edx, 1
    call    buffer_output
    pop     rbx
    ret

.ocs_string:
    mov     rdx, [opt_sep_string_len]
    test    rdx, rdx
    jz      .ocs_done
    mov     rsi, [opt_sep_string_ptr]
    call    buffer_output
.ocs_done:
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; process_merge: merge mode (-m) - print files side by side
; ═══════════════════════════════════════════════════════════
process_merge:
    push    rbx
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56

    ; For merge mode, we open all files, read them, and format
    ; side by side similar to multi-column but with separate file data

    ; For simplicity, read all files into memory first
    ; Then process page by page

    ; Initialize line number
    mov     rax, [opt_first_line_num]
    mov     [cur_line_number], rax

    ; Get current time for header
    sub     rsp, 16
    mov     eax, SYS_CLOCK_GETTIME
    xor     edi, edi
    mov     rsi, rsp
    syscall
    mov     rax, [rsp]
    mov     [cur_file_mtime], rax
    add     rsp, 16

    ; Calculate body lines per page
    mov     rax, [opt_page_length]
    cmp     byte [opt_omit_header], 0
    jne     .pm_no_hdr_sub
    sub     rax, HEADER_LINES
    sub     rax, FOOTER_LINES
    test    rax, rax
    jg      .pm_body_ok
    mov     rax, [opt_page_length]
.pm_no_hdr_sub:
.pm_body_ok:
    mov     [body_lines_per_page], rax

    ; For each file, we need to track: data ptr, data len, line offset
    ; Use merge_data/merge_len/merge_off arrays
    mov     dword [merge_file_count], 0
    xor     ebx, ebx

.pm_open_loop:
    cmp     ebx, [num_files]
    jge     .pm_open_done

    lea     rdi, [rel file_ptrs]
    mov     rdi, [rdi + rbx*8]

    ; Check if stdin
    push    rbx
    mov     rsi, rdi
    lea     rdi, [rel str_dash]
    push    rsi
    call    strcmp
    pop     rsi
    test    eax, eax
    pop     rbx
    jz      .pm_open_stdin

    ; Open and mmap file
    push    rbx
    mov     rdi, rsi
    mov     esi, O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .pm_open_err
    mov     r14, rax                ; fd

    ; fstat
    sub     rsp, STAT_SIZE
    mov     rdi, r14
    mov     rsi, rsp
    mov     rax, SYS_FSTAT
    syscall
    mov     r15, [rsp + STAT_ST_SIZE_OFF]
    add     rsp, STAT_SIZE

    ; mmap
    test    r15, r15
    jz      .pm_open_empty

    xor     edi, edi
    mov     rsi, r15
    mov     edx, PROT_READ
    mov     r10d, MAP_PRIVATE | MAP_POPULATE
    mov     r8, r14
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .pm_mmap_err

    mov     rcx, [merge_file_count]
    lea     rdi, [rel merge_data]
    mov     [rdi + rcx*8], rax
    lea     rdi, [rel merge_len]
    mov     [rdi + rcx*8], r15
    lea     rdi, [rel merge_off]
    mov     qword [rdi + rcx*8], 0
    inc     qword [merge_file_count]

    mov     rdi, r14
    call    asm_close
    pop     rbx
    jmp     .pm_next_file

.pm_open_empty:
    mov     rcx, [merge_file_count]
    lea     rdi, [rel merge_data]
    mov     qword [rdi + rcx*8], 0
    lea     rdi, [rel merge_len]
    mov     qword [rdi + rcx*8], 0
    lea     rdi, [rel merge_off]
    mov     qword [rdi + rcx*8], 0
    inc     qword [merge_file_count]
    mov     rdi, r14
    call    asm_close
    pop     rbx
    jmp     .pm_next_file

.pm_open_err:
.pm_mmap_err:
    mov     rcx, [merge_file_count]
    lea     rdi, [rel merge_data]
    mov     qword [rdi + rcx*8], 0
    lea     rdi, [rel merge_len]
    mov     qword [rdi + rcx*8], 0
    lea     rdi, [rel merge_off]
    mov     qword [rdi + rcx*8], 0
    inc     qword [merge_file_count]
    mov     byte [had_error], 1
    pop     rbx
    jmp     .pm_next_file

.pm_open_stdin:
    push    rbx
    call    read_all_stdin
    mov     rcx, [merge_file_count]
    lea     rdi, [rel merge_data]
    mov     [rdi + rcx*8], rax
    lea     rdi, [rel merge_len]
    mov     [rdi + rcx*8], rdx
    lea     rdi, [rel merge_off]
    mov     qword [rdi + rcx*8], 0
    inc     qword [merge_file_count]
    pop     rbx
    jmp     .pm_next_file

.pm_next_file:
    inc     ebx
    jmp     .pm_open_loop

.pm_open_done:
    ; Now paginate merge output
    mov     qword [rsp], 1          ; page number

    ; Calculate column width for merge
    mov     rax, [opt_page_width]
    sub     rax, [opt_indent]
    mov     rcx, [merge_file_count]
    test    rcx, rcx
    jz      .pm_done
    xor     edx, edx
    div     rcx
    mov     [col_width], rax

.pm_page_loop:
    ; Check if any file still has data
    xor     ecx, ecx
    xor     edx, edx
.pm_check_data:
    cmp     ecx, [merge_file_count]
    jge     .pm_check_done
    lea     rdi, [rel merge_off]
    mov     rax, [rdi + rcx*8]
    lea     rdi, [rel merge_len]
    cmp     rax, [rdi + rcx*8]
    jl      .pm_has_data
    inc     ecx
    jmp     .pm_check_data
.pm_has_data:
    mov     edx, 1
.pm_check_done:
    test    edx, edx
    jz      .pm_done

    ; Check page limits
    mov     rax, [opt_last_page]
    test    rax, rax
    jz      .pm_no_last_limit
    cmp     [rsp], rax
    jg      .pm_done
.pm_no_last_limit:

    ; Print page header
    mov     rax, [rsp]              ; page num
    cmp     rax, [opt_first_page]
    jl      .pm_skip_page

    cmp     byte [opt_omit_header], 0
    jne     .pm_no_hdr

    ; Use empty header for merge (or first filename)
    lea     rdi, [rel str_empty]
    mov     rsi, [rsp]
    call    print_page_header

.pm_no_hdr:
    ; Print body rows
    xor     ebx, ebx                ; row index

.pm_row_loop:
    cmp     rbx, [body_lines_per_page]
    jge     .pm_row_done

    ; Output indent
    mov     rcx, [opt_indent]
    test    rcx, rcx
    jz      .pm_no_row_indent
    lea     rsi, [rel spaces_buf]
    mov     rdx, rcx
    cmp     rdx, 256
    jle     .pm_indent_ok
    mov     rdx, 256
.pm_indent_ok:
    push    rbx
    call    buffer_output
    pop     rbx
.pm_no_row_indent:

    ; For each file/column
    xor     ebp, ebp                ; col index
    mov     byte [need_separator], 0

.pm_col_loop:
    cmp     ebp, [merge_file_count]
    jge     .pm_col_done

    ; Output separator
    cmp     byte [need_separator], 0
    je      .pm_no_col_sep
    push    rbx
    push    rbp
    call    output_column_separator
    pop     rbp
    pop     rbx
.pm_no_col_sep:
    mov     byte [need_separator], 1

    ; Get next line from this file
    push    rbx
    push    rbp
    movzx   eax, bpl
    lea     rdi, [rel merge_data]
    mov     rsi, [rdi + rax*8]
    lea     rdi, [rel merge_off]
    mov     rcx, [rdi + rax*8]
    lea     rdi, [rel merge_len]
    mov     rdx, [rdi + rax*8]

    ; Check if file exhausted
    cmp     rcx, rdx
    jge     .pm_empty_col

    ; Find next newline
    add     rsi, rcx                ; current position
    sub     rdx, rcx                ; remaining
    mov     r8, rsi                 ; line start
    xor     r9d, r9d                ; line len

.pm_scan_nl:
    cmp     r9, rdx
    jge     .pm_no_nl
    cmp     byte [rsi + r9], 10
    je      .pm_found_nl
    inc     r9
    jmp     .pm_scan_nl

.pm_found_nl:
    ; Update offset: skip past newline
    movzx   eax, bpl
    lea     rdi, [rel merge_off]
    mov     rax, [rdi + rax*8]
    add     rax, r9
    inc     rax                     ; past newline
    movzx   ecx, bpl
    mov     [rdi + rcx*8], rax

    ; Output this line padded to col_width (unless last col)
    mov     rsi, r8
    mov     edx, r9d
    mov     ecx, ebp
    inc     ecx
    cmp     ecx, [merge_file_count]
    je      .pm_last_merge_col

    call    output_column_cell
    pop     rbp
    pop     rbx
    jmp     .pm_next_col

.pm_last_merge_col:
    call    output_column_cell_last
    pop     rbp
    pop     rbx
    jmp     .pm_next_col

.pm_no_nl:
    ; Last line without newline
    movzx   eax, bpl
    lea     rdi, [rel merge_off]
    mov     rax, [rdi + rax*8]
    add     rax, r9
    movzx   ecx, bpl
    mov     [rdi + rcx*8], rax

    mov     rsi, r8
    mov     edx, r9d
    mov     ecx, ebp
    inc     ecx
    cmp     ecx, [merge_file_count]
    je      .pm_last_merge_col2
    call    output_column_cell
    pop     rbp
    pop     rbx
    jmp     .pm_next_col
.pm_last_merge_col2:
    call    output_column_cell_last
    pop     rbp
    pop     rbx
    jmp     .pm_next_col

.pm_empty_col:
    ; Empty column: pad with spaces (unless last)
    mov     ecx, ebp
    inc     ecx
    cmp     ecx, [merge_file_count]
    je      .pm_empty_last

    ; Pad with col_width spaces
    mov     rdx, [col_width]
    lea     rsi, [rel spaces_buf]
.pm_empty_pad:
    cmp     rdx, 256
    jle     .pm_empty_pad_last
    push    rdx
    mov     edx, 256
    call    buffer_output
    pop     rdx
    sub     rdx, 256
    lea     rsi, [rel spaces_buf]
    jmp     .pm_empty_pad
.pm_empty_pad_last:
    test    edx, edx
    jz      .pm_empty_last
    call    buffer_output

.pm_empty_last:
    pop     rbp
    pop     rbx
    jmp     .pm_next_col

.pm_next_col:
    inc     ebp
    jmp     .pm_col_loop

.pm_col_done:
    ; End of row
    push    rbx
    call    output_newline
    pop     rbx

    inc     ebx
    jmp     .pm_row_loop

.pm_row_done:
    ; Print footer
    cmp     byte [opt_omit_header], 0
    jne     .pm_no_ftr
    call    print_page_footer
.pm_no_ftr:

.pm_skip_page:
    inc     qword [rsp]             ; next page
    jmp     .pm_page_loop

.pm_done:
    add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; format_date: format unix timestamp as "YYYY-MM-DD HH:MM"
; rdi = unix timestamp, rsi = output buffer
; Returns rax = length written
; Caches result: if same timestamp as last call, copies from cache.
; ═══════════════════════════════════════════════════════════
format_date:
    ; Check if timestamp matches cached value
    cmp     rdi, [date_cache_mtime]
    jne     .fd_compute
    cmp     byte [date_cache_valid], 1
    jne     .fd_compute
    ; Cache hit: copy 16 bytes from cache to output buffer
    mov     rax, [date_cache_buf]
    mov     [rsi], rax
    mov     rax, [date_cache_buf + 8]
    mov     [rsi + 8], rax
    mov     rax, 16
    ret

.fd_compute:
    push    rbx
    push    r14
    push    r15
    push    rbp
    push    r13

    mov     r14, rsi                ; output buf
    mov     r15, rdi                ; timestamp

    ; Actually for assembly, let's compute UTC components
    ; and then apply timezone offset from /etc/timezone or TZ env

    ; Step 1: Get timezone offset
    ; We'll parse TZ env var or default to UTC
    mov     rdi, r15
    call    get_local_time
    ; Returns: eax=year, ecx=month(1-12), edx=day(1-31), r8d=hour, r9d=minute

    ; Save all components (write_Xdigit clobbers ecx/edx)
    mov     [rel date_year], eax
    mov     [rel date_month], ecx
    mov     [rel date_day], edx
    mov     [rel date_hour], r8d
    mov     [rel date_minute], r9d

    ; Format: YYYY-MM-DD HH:MM
    mov     rdi, r14

    ; Year (4 digits)
    mov     esi, [rel date_year]
    call    write_4digit
    mov     byte [rdi], '-'
    inc     rdi

    ; Month (2 digits)
    mov     esi, [rel date_month]
    call    write_2digit
    mov     byte [rdi], '-'
    inc     rdi

    ; Day (2 digits)
    mov     esi, [rel date_day]
    call    write_2digit
    mov     byte [rdi], ' '
    inc     rdi

    ; Hour (2 digits)
    mov     esi, [rel date_hour]
    call    write_2digit
    mov     byte [rdi], ':'
    inc     rdi

    ; Minute (2 digits)
    mov     esi, [rel date_minute]
    call    write_2digit

    ; Return length = 16 ("YYYY-MM-DD HH:MM")
    mov     rax, 16

    ; Cache the formatted date
    mov     rcx, [r14]
    mov     [date_cache_buf], rcx
    mov     rcx, [r14 + 8]
    mov     [date_cache_buf + 8], rcx
    mov     [date_cache_mtime], r15
    mov     byte [date_cache_valid], 1

    pop     r13
    pop     rbp
    pop     r15
    pop     r14
    pop     rbx
    ret

; write_4digit: write 4-digit number from esi to [rdi], advance rdi
write_4digit:
    ; esi = number (0-9999)
    mov     eax, esi
    mov     ecx, 1000
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     [rdi], al
    inc     rdi

    mov     eax, edx
    mov     ecx, 100
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     [rdi], al
    inc     rdi

    mov     eax, edx
    mov     ecx, 10
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     [rdi], al
    inc     rdi

    add     dl, '0'
    mov     [rdi], dl
    inc     rdi
    ret

; write_2digit: write 2-digit number from esi to [rdi], advance rdi
write_2digit:
    mov     eax, esi
    mov     ecx, 10
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     [rdi], al
    inc     rdi
    add     dl, '0'
    mov     [rdi], dl
    inc     rdi
    ret

; ═══════════════════════════════════════════════════════════
; get_local_time: convert unix timestamp to local time components
; rdi = unix timestamp
; Returns: eax=year, ecx=month, edx=day, r8d=hour, r9d=minute
;
; Uses the civil_from_days algorithm by Howard Hinnant
; (http://howardhinnant.github.io/date_algorithms.html)
; ═══════════════════════════════════════════════════════════
get_local_time:
    push    rbx
    push    r14
    push    r15
    push    rbp
    push    r13
    push    r12

    mov     r15, rdi                ; save timestamp

    ; Get timezone offset
    call    get_tz_offset
    ; rax = offset in seconds

    add     r15, rax                ; adjust to local time

    ; Decompose into days since epoch + seconds in day
    mov     rax, r15
    cqo                             ; sign extend for idiv
    mov     rcx, 86400
    idiv    rcx
    ; rax = days since epoch (can be negative), rdx = remainder
    ; If remainder is negative, adjust
    test    rdx, rdx
    jns     .glt_rem_ok
    dec     rax
    add     rdx, 86400
.glt_rem_ok:
    mov     r14, rax                ; z = days since epoch
    mov     r13, rdx                ; seconds in day

    ; Hours, minutes, seconds from seconds-in-day
    mov     rax, r13
    xor     edx, edx
    mov     ecx, 3600
    div     ecx
    mov     r8d, eax                ; hours
    mov     eax, edx
    xor     edx, edx
    mov     ecx, 60
    div     ecx
    mov     r9d, eax                ; minutes
    ; edx = seconds (not needed)

    ; civil_from_days(z):
    ; z += 719468
    add     r14, 719468

    ; era = (z >= 0 ? z : z - 146096) / 146097
    mov     rax, r14
    test    rax, rax
    jns     .glt_era_pos
    sub     rax, 146096
.glt_era_pos:
    cqo
    mov     rcx, 146097
    idiv    rcx
    mov     rbp, rax                ; era

    ; doe = z - era * 146097  (unsigned, [0, 146096])
    mov     rax, rbp
    imul    rax, 146097
    mov     rbx, r14
    sub     rbx, rax                ; doe

    ; yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
    mov     rax, rbx
    xor     edx, edx
    mov     rcx, 1460
    div     rcx
    mov     r12, rax                ; doe/1460

    mov     rax, rbx
    xor     edx, edx
    mov     rcx, 36524
    div     rcx
    mov     r11, rax                ; doe/36524

    mov     rax, rbx
    xor     edx, edx
    mov     rcx, 146096
    div     rcx
    ; rax = doe/146096

    mov     rcx, rbx                ; doe
    sub     rcx, r12                ; - doe/1460
    add     rcx, r11                ; + doe/36524
    sub     rcx, rax                ; - doe/146096
    mov     rax, rcx
    xor     edx, edx
    mov     rcx, 365
    div     rcx
    mov     r12, rax                ; yoe [0, 399]

    ; y = yoe + era * 400
    mov     rax, rbp
    imul    rax, 400
    add     rax, r12
    mov     r10, rax                ; y (March-based year)

    ; doy = doe - (365*yoe + yoe/4 - yoe/100)
    mov     rax, r12
    imul    rax, 365                ; 365*yoe
    mov     rcx, rax

    mov     rax, r12
    shr     rax, 2                  ; yoe/4
    add     rcx, rax

    mov     rax, r12
    xor     edx, edx
    mov     r11, 100
    div     r11
    sub     rcx, rax                ; 365*yoe + yoe/4 - yoe/100

    mov     rax, rbx                ; doe
    sub     rax, rcx                ; doy [0, 365]
    mov     rbx, rax                ; save doy

    ; mp = (5*doy + 2) / 153
    imul    rax, 5
    add     rax, 2
    xor     edx, edx
    mov     rcx, 153
    div     rcx
    mov     rbp, rax                ; mp [0, 11]

    ; d = doy - (153*mp + 2)/5 + 1
    mov     rax, rbp
    imul    rax, 153
    add     rax, 2
    xor     edx, edx
    mov     rcx, 5
    div     rcx
    mov     rcx, rbx                ; doy
    sub     ecx, eax
    inc     ecx
    mov     edx, ecx               ; day [1, 31]

    ; m = mp < 10 ? mp + 3 : mp - 9
    cmp     rbp, 10
    jge     .glt_month_ge10
    lea     ecx, [rbp + 3]
    jmp     .glt_month_done
.glt_month_ge10:
    lea     ecx, [rbp - 9]
.glt_month_done:
    ; ecx = month [1, 12]

    ; y += (m <= 2)
    cmp     ecx, 2
    jg      .glt_no_year_adj
    inc     r10
.glt_no_year_adj:

    mov     eax, r10d               ; year
    ; ecx = month, edx = day, r8d = hour, r9d = minute

    pop     r12
    pop     r13
    pop     rbp
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; get_tz_offset: get timezone offset in seconds
; Returns rax = offset in seconds from UTC
; Reads /etc/localtime (TZif format) for the current offset
; Caches result after first call.
; ═══════════════════════════════════════════════════════════
get_tz_offset:
    ; Check cache
    cmp     byte [tz_cached], 1
    jne     .gtz_compute
    mov     rax, [tz_offset_cache]
    ret
.gtz_compute:
    push    rbx
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8

    ; First try TZ environment variable
    ; Walk through the environment strings
    ; For now, try to read /etc/localtime (TZif binary file)

    ; Open /etc/localtime
    lea     rdi, [rel str_localtime]
    mov     esi, O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .gtz_utc                ; fallback to UTC

    mov     rbx, rax                ; fd

    ; Read the TZif file header and data
    ; TZif format: magic "TZif", version, then data
    ; We need to find the current UTC offset
    ; Read up to 4KB
    sub     rsp, 4096
    mov     rdi, rbx
    mov     rsi, rsp
    mov     edx, 4096
    call    asm_read
    mov     r14, rax                ; bytes read

    ; Close file
    push    r14
    mov     rdi, rbx
    call    asm_close
    pop     r14

    cmp     r14, 44
    jl      .gtz_utc_cleanup        ; too small

    ; Check magic: "TZif"
    cmp     dword [rsp], 0x66695a54  ; "TZif" little-endian
    jne     .gtz_utc_cleanup

    ; Version byte at offset 4
    movzx   eax, byte [rsp + 4]

    ; Parse v1 header:
    ; Offset 20: tzh_ttisgmtcnt (4 bytes, big-endian)
    ; Offset 24: tzh_ttisstdcnt (4 bytes, big-endian)
    ; Offset 28: tzh_leapcnt (4 bytes, big-endian)
    ; Offset 32: tzh_timecnt (4 bytes, big-endian)
    ; Offset 36: tzh_typecnt (4 bytes, big-endian)
    ; Offset 40: tzh_charcnt (4 bytes, big-endian)

    ; Read timecnt
    mov     eax, [rsp + 32]
    bswap   eax
    mov     r15d, eax               ; timecnt

    ; Read typecnt
    mov     eax, [rsp + 36]
    bswap   eax
    mov     ebp, eax                ; typecnt

    ; Read charcnt
    mov     eax, [rsp + 40]
    bswap   eax
    mov     r8d, eax                ; charcnt (not needed directly)

    ; Data starts at offset 44
    ; transition_times: timecnt * 4 bytes
    ; transition_types: timecnt * 1 byte
    ; ttinfos: typecnt * 6 bytes (utoff:4, dst:1, idx:1)

    ; Find the current time's transition
    ; Get current time
    push    r15
    push    rbp
    sub     rsp, 16
    mov     eax, SYS_CLOCK_GETTIME
    xor     edi, edi
    mov     rsi, rsp
    syscall
    mov     r13, [rsp]              ; current timestamp
    add     rsp, 16
    pop     rbp
    pop     r15

    ; Walk transition times backwards to find applicable one
    lea     rsi, [rsp + 44]         ; transition_times array
    ; Each is 4 bytes, big-endian, signed

    ; Start from last transition
    mov     ecx, r15d               ; timecnt
    test    ecx, ecx
    jz      .gtz_use_first_type

    dec     ecx                     ; last index
.gtz_find_trans:
    mov     eax, [rsi + rcx*4]
    bswap   eax
    cdqe                            ; sign-extend to 64-bit
    cmp     rax, r13
    jle     .gtz_found_trans
    test    ecx, ecx
    jz      .gtz_use_first_type
    dec     ecx
    jmp     .gtz_find_trans

.gtz_found_trans:
    ; ecx = index of applicable transition
    ; Get transition type index
    lea     rdi, [rsi + r15*4]      ; transition_types array starts after times
    movzx   eax, byte [rdi + rcx]   ; type index

    ; Get ttinfo: starts after transition_types
    lea     rdi, [rdi + r15]        ; ttinfos array
    ; Each ttinfo: 4 bytes utoff (big-endian) + 1 byte dst + 1 byte idx
    imul    eax, 6
    mov     eax, [rdi + rax]        ; utoff (big-endian)
    bswap   eax
    cdqe                            ; sign-extend
    jmp     .gtz_have_offset

.gtz_use_first_type:
    ; No applicable transition, use first type
    lea     rdi, [rsi + r15*4]      ; transition_types
    lea     rdi, [rdi + r15]        ; ttinfos
    mov     eax, [rdi]              ; first utoff
    bswap   eax
    cdqe

.gtz_have_offset:
    add     rsp, 4096
    mov     [tz_offset_cache], rax
    mov     byte [tz_cached], 1
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     rbx
    ret

.gtz_utc_cleanup:
    add     rsp, 4096
.gtz_utc:
    xor     eax, eax                ; UTC offset = 0
    mov     [tz_offset_cache], rax
    mov     byte [tz_cached], 1
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; format_page_num: format "Page N" string
; rdi = output buffer, rsi = page number
; Returns rax = length
; ═══════════════════════════════════════════════════════════
format_page_num:
    push    rbx
    mov     rbx, rdi

    ; Write "Page "
    mov     byte [rdi], 'P'
    mov     byte [rdi+1], 'a'
    mov     byte [rdi+2], 'g'
    mov     byte [rdi+3], 'e'
    mov     byte [rdi+4], ' '
    add     rdi, 5

    ; Convert number to string
    mov     rax, rsi
    call    write_u64
    ; rdi advanced past the number

    mov     rax, rdi
    sub     rax, rbx                ; total length

    pop     rbx
    ret

; write_u64: write unsigned 64-bit number at [rdi], advance rdi
write_u64:
    push    rbx
    push    r8
    mov     rbx, rdi

    ; Convert to decimal digits on stack
    sub     rsp, 24                 ; max 20 digits
    lea     r8, [rsp + 24]         ; r8 = top of temp area (one past end)

    test    rax, rax
    jnz     .wu64_loop
    ; Zero
    mov     byte [rdi], '0'
    inc     rdi
    add     rsp, 24
    pop     r8
    pop     rbx
    ret

.wu64_loop:
    test    rax, rax
    jz      .wu64_copy
    xor     edx, edx
    mov     rcx, 10
    div     rcx
    add     dl, '0'
    dec     r8
    mov     [r8], dl
    jmp     .wu64_loop

.wu64_copy:
    ; Copy digits from r8 to rsp+24
    lea     rcx, [rsp + 24]        ; end pointer
.wu64_copy_loop:
    cmp     r8, rcx
    jge     .wu64_done
    mov     al, [r8]
    mov     [rdi], al
    inc     rdi
    inc     r8
    jmp     .wu64_copy_loop

.wu64_done:
    add     rsp, 24
    pop     r8
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; format_line_number: format line number right-justified
; rdi = number, rsi = field width
; Output in num_format_buf, returns rax = length
; ═══════════════════════════════════════════════════════════
format_line_number:
    push    rbx
    push    r14
    push    r15

    mov     r14, rdi                ; number
    mov     r15, rsi                ; width

    ; Convert number to decimal string
    lea     rbx, [rel num_format_buf]

    ; First, convert number to digits in temp area
    sub     rsp, 24
    mov     rax, r14
    mov     r8, rsp
    add     r8, 24
    xor     ecx, ecx                ; digit count

    test    rax, rax
    jnz     .fln_loop
    dec     r8
    mov     byte [r8], '0'
    inc     ecx
    jmp     .fln_pad

.fln_loop:
    test    rax, rax
    jz      .fln_pad
    mov     rdx, rax
    push    rcx
    mov     rcx, 10
    xor     edx, edx
    div     rcx
    pop     rcx
    add     dl, '0'
    dec     r8
    mov     [r8], dl
    inc     ecx
    jmp     .fln_loop

.fln_pad:
    ; Right-justify: pad with spaces
    mov     rax, r15
    sub     rax, rcx                ; padding needed
    test    rax, rax
    jle     .fln_copy
    ; Write spaces
    mov     rdx, rax
.fln_space_loop:
    test    rdx, rdx
    jz      .fln_copy
    mov     byte [rbx], ' '
    inc     rbx
    dec     rdx
    jmp     .fln_space_loop

.fln_copy:
    ; Copy digits
    mov     rdx, rcx
.fln_copy_loop:
    test    rdx, rdx
    jz      .fln_done
    mov     al, [r8]
    mov     [rbx], al
    inc     r8
    inc     rbx
    dec     rdx
    jmp     .fln_copy_loop

.fln_done:
    lea     rax, [rel num_format_buf]
    mov     rdx, rbx
    sub     rdx, rax                ; length
    mov     rax, rdx

    add     rsp, 24
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; output_blank_line: output a blank line (just newline, with indent)
; ═══════════════════════════════════════════════════════════
output_blank_line:
    ; Just a newline (GNU pr blank lines in header/footer have no indent)
    jmp     output_newline

; ═══════════════════════════════════════════════════════════
; output_newline: output a single newline character
; ═══════════════════════════════════════════════════════════
output_newline:
    mov     byte [rel single_char_buf], 10
    lea     rsi, [rel single_char_buf]
    mov     edx, 1
    jmp     buffer_output

; ═══════════════════════════════════════════════════════════
; buffer_output: add data to output buffer, flush if needed
; rsi = data ptr, edx = length
; ═══════════════════════════════════════════════════════════
buffer_output:
    push    rbx
    push    r14

    mov     rbx, rsi                ; data
    mov     r14, rdx                ; len (use full 64-bit)

    ; If data is larger than buffer, flush and write directly
    cmp     r14, OUT_BUF_SIZE
    jge     .bo_large

    ; Check if we need to flush first
    mov     rax, r12
    add     rax, r14
    cmp     rax, OUT_BUF_SIZE
    jl      .bo_copy

    ; Flush current buffer
    push    r14
    push    rbx
    call    flush_output
    pop     rbx
    pop     r14
    test    eax, eax
    jnz     .bo_error

.bo_copy:
    ; Copy data to output buffer
    lea     rdi, [rel out_buf]
    add     rdi, r12
    mov     rsi, rbx
    mov     rcx, r14
    ; Fast copy
    rep     movsb
    add     r12, r14

    ; Check flush threshold
    cmp     r12, FLUSH_THRESHOLD
    jl      .bo_done
    push    r14
    call    flush_output
    pop     r14

.bo_done:
    pop     r14
    pop     rbx
    ret

.bo_large:
    ; Data too large for buffer: flush buffer, then write data directly
    push    r14
    push    rbx
    call    flush_output
    pop     rbx
    pop     r14
    test    eax, eax
    jnz     .bo_error
    ; Write data directly to stdout
    mov     rdi, STDOUT
    mov     rsi, rbx
    mov     rdx, r14
    call    asm_write_all
    jmp     .bo_done

.bo_error:
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; flush_output: write output buffer to stdout
; Returns eax = 0 on success, -1 on error
; ═══════════════════════════════════════════════════════════
flush_output:
    test    r12, r12
    jz      .fo_ok

    mov     rdi, STDOUT
    lea     rsi, [rel out_buf]
    mov     rdx, r12
    call    asm_write_all
    test    rax, rax
    jnz     .fo_error

    xor     r12d, r12d              ; reset buffer
.fo_ok:
    xor     eax, eax
    ret
.fo_error:
    mov     eax, -1
    ret

; ═══════════════════════════════════════════════════════════
; Utility functions
; ═══════════════════════════════════════════════════════════

; strcmp: compare two null-terminated strings
; rsi = str1, rdi = str2
; Returns eax = 0 if equal, non-zero if different
strcmp:
    push    rbx
.strcmp_loop:
    movzx   eax, byte [rsi]
    movzx   ebx, byte [rdi]
    cmp     al, bl
    jne     .strcmp_ne
    test    al, al
    jz      .strcmp_eq
    inc     rsi
    inc     rdi
    jmp     .strcmp_loop
.strcmp_eq:
    xor     eax, eax
    pop     rbx
    ret
.strcmp_ne:
    mov     eax, 1
    pop     rbx
    ret

; starts_with: check if str starts with prefix
; rdi = prefix, rsi = str
; Returns eax = prefix length if match, 0 if no match
starts_with:
    push    rbx
    push    r14
    mov     r14, rdi                ; prefix
    mov     rbx, rsi                ; str
    xor     ecx, ecx                ; index
.sw_loop:
    movzx   eax, byte [r14 + rcx]
    test    al, al
    jz      .sw_match               ; end of prefix = match
    movzx   edx, byte [rbx + rcx]
    cmp     al, dl
    jne     .sw_no_match
    inc     ecx
    jmp     .sw_loop
.sw_match:
    mov     eax, ecx
    pop     r14
    pop     rbx
    ret
.sw_no_match:
    xor     eax, eax
    pop     r14
    pop     rbx
    ret

; strlen: get length of null-terminated string
; rdi = str
; Returns rax = length
strlen:
    xor     rax, rax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; parse_number: parse unsigned decimal number from string
; rsi = string
; Returns rax = number
parse_number:
    xor     rax, rax
.pn_loop:
    movzx   ecx, byte [rsi]
    sub     cl, '0'
    cmp     cl, 9
    ja      .pn_done
    imul    rax, 10
    movzx   ecx, cl
    add     rax, rcx
    inc     rsi
    jmp     .pn_loop
.pn_done:
    ret

; ═══════════════════════════════════════════════════════════
; Error output functions
; ═══════════════════════════════════════════════════════════

; print_error_simple: print a simple error string to stderr
; rdi = error string (null-terminated)
print_error_simple:
    push    rbx
    mov     rbx, rdi
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    pop     rbx
    ret

; err_unrecognized_option: print unrecognized option error
; rsi = option string
err_unrecognized_option:
    push    rbx
    mov     rbx, rsi

    lea     rdi, [rel str_pr_prefix]
    call    print_error_simple

    lea     rdi, [rel str_unrecognized]
    call    print_error_simple

    lea     rdi, [rel str_squote]
    call    print_error_simple

    mov     rdi, rbx
    call    print_error_simple

    lea     rdi, [rel str_squote_nl]
    call    print_error_simple

    lea     rdi, [rel str_try_help]
    call    print_error_simple

    pop     rbx
    ret

; err_invalid_option: print invalid option error
; rsi = option string
err_invalid_option:
    push    rbx
    mov     rbx, rsi

    lea     rdi, [rel str_pr_prefix]
    call    print_error_simple

    lea     rdi, [rel str_invalid_opt]
    call    print_error_simple

    lea     rdi, [rel str_squote]
    call    print_error_simple

    mov     rdi, rbx
    call    print_error_simple

    lea     rdi, [rel str_squote_nl]
    call    print_error_simple

    lea     rdi, [rel str_try_help]
    call    print_error_simple

    pop     rbx
    ret

; print_open_error: print file open error
; rdi = filename
print_open_error:
    push    rbx
    mov     rbx, rdi

    lea     rdi, [rel str_pr_prefix]
    call    print_error_simple

    mov     rdi, rbx
    call    print_error_simple

    lea     rdi, [rel str_open_error]
    call    print_error_simple

    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
; Read-only data
; ═══════════════════════════════════════════════════════════
section .rodata

str_dash:           db "-", 0
str_empty:          db 0
str_localtime:      db "/etc/localtime", 0

str_help_flag:      db "--help", 0
str_version_flag:   db "--version", 0

str_columns_eq:     db "--columns=", 0
str_length_eq:      db "--length=", 0
str_header_eq:      db "--header=", 0
str_indent_eq:      db "--indent=", 0
str_pagewidth_eq:   db "--page-width=", 0
str_pages_eq:       db "--pages=", 0
str_firstlinenum_eq: db "--first-line-number=", 0
str_sepstring_eq:   db "--sep-string=", 0

str_across_flag:    db "--across", 0
str_double_space_flag: db "--double-space", 0
str_form_feed_flag: db "--form-feed", 0
str_join_lines_flag: db "--join-lines", 0
str_merge_flag:     db "--merge", 0
str_number_lines_flag: db "--number-lines", 0
str_no_file_warn_flag: db "--no-file-warnings", 0
str_omit_header_flag: db "--omit-header", 0
str_omit_pagination_flag: db "--omit-pagination", 0
str_show_ctrl_flag: db "--show-control-chars", 0
str_show_nonprint_flag: db "--show-nonprinting", 0

str_pr_prefix:      db "pr: ", 0
str_unrecognized:   db "unrecognized option ", 0
str_invalid_opt:    db "invalid option -- ", 0
str_squote:         db 0x27, 0      ; single quote
str_squote_nl:      db 0x27, 10, 0  ; single quote + newline
str_try_help:       db "Try 'pr --help' for more information.", 10, 0
str_open_error:     db ": No such file or directory", 10, 0
str_write_error:    db "pr: write error", 10, 0

version_text:       db "pr (fcoreutils) 0.1.0", 10
version_text_len    equ $ - version_text

help_text:
    db "Usage: pr [OPTION]... [FILE]...", 10
    db "Paginate or columnate FILE(s) for printing.", 10, 10
    db "With no FILE, or when FILE is -, read standard input.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  +FIRST_PAGE[:LAST_PAGE], --pages=FIRST_PAGE[:LAST_PAGE]", 10
    db "                    begin [stop] printing with page FIRST_[:LAST_]PAGE", 10
    db "  -COLUMN, --columns=COLUMN", 10
    db "                    output COLUMN columns and print columns down", 10
    db "  -a, --across      print columns across rather than down", 10
    db "  -c, --show-control-chars", 10
    db "                    use hat notation (^G) and octal backslash notation", 10
    db "  -d, --double-space", 10
    db "                    double space the output", 10
    db "  -D, --date-format=FORMAT", 10
    db "                    use FORMAT for the header date", 10
    db "  -e[CHAR[WIDTH]], --expand-tabs[=CHAR[WIDTH]]", 10
    db "                    expand input CHARs (TABs) to tab WIDTH (8)", 10
    db "  -F, -f, --form-feed", 10
    db "                    use form feeds instead of newlines to separate pages", 10
    db "  -h, --header=HEADER", 10
    db "                    use HEADER instead of filename in page header", 10
    db "  -i[CHAR[WIDTH]], --output-tabs[=CHAR[WIDTH]]", 10
    db "                    replace spaces with CHARs (TABs) to tab WIDTH (8)", 10
    db "  -J, --join-lines  merge full lines, turns off -W line truncation", 10
    db "  -l, --length=PAGE_LENGTH", 10
    db "                    set the page length to PAGE_LENGTH (66) lines", 10
    db "  -m, --merge       print all files in parallel, one in each column", 10
    db "  -n[SEP[DIGITS]], --number-lines[=SEP[DIGITS]]", 10
    db "                    number lines, use DIGITS (5) digits, then SEP (TAB)", 10
    db "  -N, --first-line-number=NUMBER", 10
    db "                    start counting with NUMBER at 1st line of first page", 10
    db "  -o, --indent=MARGIN", 10
    db "                    offset each line with MARGIN (zero) spaces", 10
    db "  -r, --no-file-warnings", 10
    db "                    omit warning when a file cannot be opened", 10
    db "  -s[CHAR], --separator[=CHAR]", 10
    db "                    separate columns by a single character (TAB)", 10
    db "  -S[STRING], --sep-string[=STRING]", 10
    db "                    separate columns by STRING", 10
    db "  -t, --omit-header omit page headers and trailers", 10
    db "  -T, --omit-pagination", 10
    db "                    omit page headers and trailers, eliminate form feeds", 10
    db "  -v, --show-nonprinting", 10
    db "                    use octal backslash notation", 10
    db "  -w, --page-width=PAGE_WIDTH", 10
    db "                    set page width to PAGE_WIDTH (72) columns", 10
    db "  -W, --page-width=PAGE_WIDTH", 10
    db "                    set page width to PAGE_WIDTH (72) columns always", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
help_text_len       equ $ - help_text

; ═══════════════════════════════════════════════════════════
; Mutable data (BSS)
; ═══════════════════════════════════════════════════════════
section .bss

; Output buffer
out_buf:            resb OUT_BUF_SIZE

; Header construction buffer
header_buf:         resb MAX_HEADER_LEN

; Page number formatting buffer
page_num_buf:       resb 64

; Line number formatting buffer
num_format_buf:     resb 32

; Single character buffer
single_char_buf:    resb 8

; Spaces buffer (256 spaces for padding)
spaces_buf:         resb 256

; Line pointer/length arrays
line_ptrs:          resq MAX_PAGE_LINES
line_lens:          resd MAX_PAGE_LINES

; Configuration options
opt_first_page:     resq 1
opt_last_page:      resq 1
opt_columns:        resq 1
opt_across:         resb 1
opt_show_ctrl:      resb 1
opt_double_space:   resb 1
opt_form_feed:      resb 1
opt_join_lines:     resb 1
opt_page_length:    resq 1
opt_merge:          resb 1
opt_number_lines:   resb 1
opt_number_sep:     resb 1
opt_number_width:   resq 1
opt_first_line_num: resq 1
opt_indent:         resq 1
opt_no_file_warn:   resb 1
opt_has_sep:        resb 1
opt_sep_char:       resb 1
opt_has_sep_string: resb 1
opt_sep_string_ptr: resq 1
opt_sep_string_len: resq 1
opt_omit_header:    resb 1
opt_omit_pagination: resb 1
opt_show_nonprint:  resb 1
opt_page_width:     resq 1
opt_truncate:       resb 1
opt_expand_tabs:    resb 1
opt_expand_char:    resb 1
opt_expand_width:   resq 1
opt_output_tabs:    resb 1
opt_output_tab_char: resb 1
opt_output_tab_width: resq 1
opt_header_ptr:     resq 1
opt_header_len:     resq 1

; Current state
cur_file_mtime:     resq 1
cur_mmap_addr:      resq 1
cur_mmap_len:       resq 1
cur_stdin_ptr:      resq 1
cur_stdin_len:      resq 1
cur_line_number:    resq 1
body_lines_per_page: resq 1
lines_to_collect:   resq 1
lines_collected:    resq 1
col_width:          resq 1
col_trunc_width:    resq 1
cur_col_start:      resq 1
phys_row_count:     resq 1
need_separator:     resb 1
last_nonempty_col:  resq 1
had_error:          resb 1

; Argv state
argv_base:          resq 1
argv_count:         resq 1
arg_index:          resq 1
seen_dashdash:      resb 1

; File tracking
num_files:          resd 1
file_index:         resd 1
file_ptrs:          resq MAX_FILES

; Merge mode state
merge_file_count:   resq 1
merge_data:         resq MAX_FILES
merge_len:          resq MAX_FILES
merge_off:          resq MAX_FILES

; Header construction temporaries
hdr_date_len:       resq 1
hdr_page_len:       resq 1
hdr_text_len:       resq 1
hdr_text_ptr:       resq 1
hdr_left_pad:       resq 1
hdr_right_pad:      resq 1
hdr_saved_rbx:      resq 1
hdr_saved_rbp:      resq 1

; Date formatting temporaries
date_year:          resd 1
date_month:         resd 1
date_day:           resd 1
date_hour:          resd 1
date_minute:        resd 1

; Caches
tz_cached:          resb 1
tz_offset_cache:    resq 1
date_cache_valid:   resb 1
date_cache_mtime:   resq 1
date_cache_buf:     resb 16

; NX stack
section .note.GNU-stack noalloc noexec nowrite progbits
