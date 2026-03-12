; ============================================================================
;  ffmt_unified.asm — Unified single-file build of ffmt
;  Simple text formatter (word-wrap), GNU fmt compatible
;  Build: nasm -f bin unified/ffmt_unified.asm -o ffmt && chmod +x ffmt
; ============================================================================

BITS 64
org 0x400000

; ── Linux syscall numbers and constants ──
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_RT_SIGPROCMASK 14
%define SYS_EXIT           60

%define STDIN               0
%define STDOUT              1
%define STDERR              2
%define O_RDONLY            0
%define SIGPIPE            13
%define EINTR               4

; ── Constants ──
%define INPUT_BUF_SIZE  262144
%define OUT_BUF_SIZE    524288
%define FLUSH_THRESHOLD 262144
%define MAX_FILES       256
%define MAX_WORDS       16384
%define DEFAULT_WIDTH   75

; ── BSS layout ──
%define BSS_BASE        0x500000
%define width           BSS_BASE
%define argc_rem        (width + 4)
%define flag_split      (argc_rem + 4)
%define flag_uniform    (flag_split + 1)
%define past_dashdash   (flag_uniform + 1)
%define exit_code       (past_dashdash + 1)
%define opt_char_buf    (exit_code + 1)
%define first_line_para (opt_char_buf + 2)
%define line_has_content (first_line_para + 1)
%define tmp_char        (line_has_content + 1)
%define para_indent     (tmp_char + 4)
%define num_files       (para_indent + 4)
%define word_count      (num_files + 4)
%define out_pos         (word_count + 8)
%define files           (out_pos + 8)
%define para_indent_buf (files + MAX_FILES * 8)
%define word_starts     (para_indent_buf + 1024)
%define word_lengths    (word_starts + MAX_WORDS * 8)
%define input_buf       (word_lengths + MAX_WORDS * 4)
%define out_buf         (input_buf + INPUT_BUF_SIZE)
%define BSS_END         (out_buf + OUT_BUF_SIZE)
%define BSS_SIZE        (BSS_END - BSS_BASE)

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
    dw      3
    dw      0, 0, 0
ehdr_end:

; ── Program Headers ──
phdr:
    ; Code + Data (R+X)
    dd      1
    dd      5
    dq      0
    dq      0x400000
    dq      0x400000
    dq      file_end - ehdr
    dq      file_end - ehdr
    dq      0x1000
phdr_size equ $ - phdr

    ; BSS (R+W)
    dd      1
    dd      6
    dq      0
    dq      BSS_BASE
    dq      BSS_BASE
    dq      0
    dq      BSS_SIZE
    dq      0x1000

    ; GNU_STACK (NX)
    dd      0x6474E551
    dd      6
    dq      0, 0, 0, 0, 0
    dq      0x10

; ============================================================================
;                           CODE SECTION
; ============================================================================

_start:
    BLOCK_SIGPIPE

    mov     ecx, [rsp]
    lea     r14, [rsp + 8]

    ; Initialize defaults
    mov     dword [width], DEFAULT_WIDTH
    mov     byte [flag_split], 0
    mov     byte [flag_uniform], 0
    mov     dword [num_files], 0
    mov     byte [exit_code], 0

    ; Parse arguments
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

    ; Short options
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

.next_arg:
    add     rbx, 8
    dec     dword [argc_rem]
    jmp     .parse_loop

.parse_done:
    ; Initialize output buffer position
    mov     qword [out_pos], 0

    mov     eax, [num_files]
    test    eax, eax
    jnz     .process_files

    ; No files — read stdin
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
    push    rsi
    mov     rdi, rsi
    xor     esi, esi
    xor     edx, edx
    mov     rax, SYS_OPEN
    syscall
    test    rax, rax
    js      .open_error

    mov     edi, eax
    push    rdi
    call    process_fd
    pop     rdi
    mov     rax, SYS_CLOSE
    syscall
    pop     rsi
    pop     r13
    jmp     .next_file

.open_error:
    pop     rsi
    push    r13
    push    rsi
    mov     rdi, str_prefix
    mov     edx, str_prefix_len
    call    write_stderr
    mov     rdi, str_cannot_open
    mov     edx, str_cannot_open_len
    call    write_stderr
    pop     rsi
    push    rsi
    mov     rdi, rsi
    call    strlen
    mov     rdx, rax
    mov     rdi, rsi
    call    write_stderr_buf
    mov     rdi, str_for_reading
    mov     edx, str_for_reading_len
    call    write_stderr
    pop     rsi
    mov     byte [exit_code], 1
    pop     r13

.next_file:
    inc     r13d
    jmp     .file_loop

.final_flush:
    call    flush_output

    movzx   rdi, byte [exit_code]
    EXIT    rdi

; ============================================================================
;  Argument parsing
; ============================================================================
parse_short_options:
    push    rbx

.pso_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .pso_done

    cmp     al, 's'
    je      .pso_split
    cmp     al, 'u'
    je      .pso_uniform
    cmp     al, 'w'
    je      .pso_width
    jmp     .pso_invalid

.pso_split:
    mov     byte [flag_split], 1
    inc     rsi
    jmp     .pso_loop

.pso_uniform:
    mov     byte [flag_uniform], 1
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
    mov     rdi, str_dashdash_split
    call    strcmp
    test    eax, eax
    jz      .plo_split

    mov     rsi, [rbx]
    mov     rdi, str_dashdash_uniform
    call    strcmp
    test    eax, eax
    jz      .plo_uniform

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

.plo_split:
    mov     byte [flag_split], 1
    pop     rbx
    ret

.plo_uniform:
    mov     byte [flag_uniform], 1
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
;  process_fd — Read all input from fd, then format paragraphs
;  Uses r12 = total bytes, r13 = current pos in input
; ============================================================================
process_fd:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     ebx, edi

    ; Read all input into input_buf
    xor     r12d, r12d          ; total bytes read

.read_loop:
    mov     rax, SYS_READ
    mov     edi, ebx
    lea     rsi, [input_buf + r12]
    mov     edx, INPUT_BUF_SIZE
    sub     edx, r12d
    test    edx, edx
    jle     .read_done
    syscall
    cmp     rax, -EINTR
    je      .read_loop
    test    rax, rax
    js      .read_done
    jz      .read_done
    add     r12, rax
    jmp     .read_loop

.read_done:
    test    r12, r12
    jz      .proc_done

    xor     r13d, r13d          ; current position in input

.process_loop:
    cmp     r13, r12
    jge     .proc_done

    ; Check for blank line (paragraph separator)
    cmp     byte [input_buf + r13], 10
    jne     .not_blank_line

    ; Output a blank line
    call    emit_newline
    inc     r13
    jmp     .process_loop

.not_blank_line:
    ; Measure indentation of first line
    call    measure_indent      ; eax = indent byte count
    mov     [para_indent], eax

    ; Collect words from this paragraph
    mov     dword [word_count], 0
    call    collect_paragraph

    ; Format and output the paragraph
    call    format_paragraph

    jmp     .process_loop

.proc_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; measure_indent — count leading spaces/tabs at input_buf[r13]
; Returns: eax = number of indent bytes
; Copies indent chars to para_indent_buf
; Does NOT advance r13
; ============================================================================
measure_indent:
    xor     eax, eax
.mi_loop:
    lea     rcx, [r13 + rax]
    cmp     rcx, r12
    jge     .mi_done
    movzx   edx, byte [input_buf + rcx]
    cmp     dl, ' '
    je      .mi_copy
    cmp     dl, 9
    je      .mi_copy
    jmp     .mi_done
.mi_copy:
    mov     [para_indent_buf + rax], dl
    inc     eax
    cmp     eax, 1024
    jl      .mi_loop
.mi_done:
    ret

; ============================================================================
; collect_paragraph — Collect words from consecutive same-indent lines
; r13 = current pos, r12 = total length
; ============================================================================
collect_paragraph:
    push    rbx
    push    r14
    push    r15

    mov     dword [word_count], 0
    mov     byte [first_line_para], 1

.cp_line_loop:
    cmp     r13, r12
    jge     .cp_done

    cmp     byte [input_buf + r13], 10
    je      .cp_done

    ; For non-first lines: check indentation matches
    cmp     byte [first_line_para], 1
    je      .cp_skip_indent_check

    ; Measure indent of this line
    call    measure_indent_temp
    ; ebx = indent len of this line
    cmp     ebx, [para_indent]
    jne     .cp_done

    ; Compare indent chars
    xor     ecx, ecx
.cp_cmp_indent:
    cmp     ecx, ebx
    jge     .cp_indent_ok
    lea     rdx, [r13 + rcx]
    movzx   eax, byte [input_buf + rdx]
    cmp     al, [para_indent_buf + rcx]
    jne     .cp_done
    inc     ecx
    jmp     .cp_cmp_indent

.cp_indent_ok:
.cp_skip_indent_check:
    mov     byte [first_line_para], 0

    ; Skip past indentation
    mov     eax, [para_indent]
    add     r13, rax

    ; Collect words from this line
.cp_word_loop:
    cmp     r13, r12
    jge     .cp_done

    movzx   eax, byte [input_buf + r13]
    cmp     al, 10
    je      .cp_line_done

    ; Skip spaces
    cmp     al, ' '
    je      .cp_skip_space
    cmp     al, 9
    je      .cp_skip_space

    ; Start of a word
    mov     eax, [word_count]
    cmp     eax, MAX_WORDS
    jge     .cp_skip_word

    ; Record word start pointer
    lea     rcx, [input_buf + r13]
    mov     [word_starts + rax*8], rcx

    ; Find word end
    xor     ecx, ecx
.cp_find_end:
    lea     rdx, [r13 + rcx]
    cmp     rdx, r12
    jge     .cp_word_found
    movzx   edx, byte [input_buf + r13 + rcx]
    cmp     dl, ' '
    je      .cp_word_found
    cmp     dl, 9
    je      .cp_word_found
    cmp     dl, 10
    je      .cp_word_found
    inc     ecx
    jmp     .cp_find_end

.cp_word_found:
    mov     eax, [word_count]
    mov     [word_lengths + rax*4], ecx
    inc     dword [word_count]
    add     r13, rcx
    jmp     .cp_word_loop

.cp_skip_word:
    inc     r13
    cmp     r13, r12
    jge     .cp_done
    movzx   eax, byte [input_buf + r13]
    cmp     al, ' '
    je      .cp_word_loop
    cmp     al, 9
    je      .cp_word_loop
    cmp     al, 10
    je      .cp_line_done
    jmp     .cp_skip_word

.cp_skip_space:
    inc     r13
    jmp     .cp_word_loop

.cp_line_done:
    inc     r13             ; skip newline

    ; In split-only mode, don't join lines
    cmp     byte [flag_split], 0
    jne     .cp_done

    jmp     .cp_line_loop

.cp_done:
    pop     r15
    pop     r14
    pop     rbx
    ret

; ============================================================================
; measure_indent_temp — like measure_indent but returns in ebx, no copy
; ============================================================================
measure_indent_temp:
    xor     ebx, ebx
.mit_loop:
    lea     rcx, [r13 + rbx]
    cmp     rcx, r12
    jge     .mit_done
    movzx   edx, byte [input_buf + rcx]
    cmp     dl, ' '
    je      .mit_next
    cmp     dl, 9
    je      .mit_next
    jmp     .mit_done
.mit_next:
    inc     ebx
    cmp     ebx, 1024
    jl      .mit_loop
.mit_done:
    ret

; ============================================================================
; format_paragraph — Output words wrapped to [width]
; ============================================================================
format_paragraph:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     eax, [word_count]
    test    eax, eax
    jz      .fp_done

    ; Start first line with indent
    call    emit_indent

    ; Calculate display width of indent
    call    calc_indent_display_width
    mov     r14d, eax           ; r14d = current column

    xor     r15d, r15d          ; r15d = current word index
    mov     byte [line_has_content], 0

.fp_word_loop:
    cmp     r15d, [word_count]
    jge     .fp_end_line

    ; Get word info
    mov     rsi, [word_starts + r15*8]
    mov     ecx, [word_lengths + r15*4]

    ; If not first word on line, need a space before it
    cmp     byte [line_has_content], 0
    je      .fp_emit_word

    ; Check if word fits: col + 1(space) + word_len <= width
    lea     eax, [r14d + 1]
    add     eax, ecx
    cmp     eax, [width]
    jle     .fp_add_space

    ; Word doesn't fit — start new line
    call    emit_newline
    call    emit_indent
    call    calc_indent_display_width
    mov     r14d, eax
    mov     byte [line_has_content], 0
    jmp     .fp_emit_word

.fp_add_space:
    mov     byte [tmp_char], ' '
    push    rcx
    push    rsi
    mov     rdi, tmp_char
    mov     edx, 1
    call    emit_bytes
    pop     rsi
    pop     rcx
    inc     r14d

.fp_emit_word:
    push    rcx
    mov     rdi, rsi
    mov     edx, ecx
    call    emit_bytes
    pop     rcx
    add     r14d, ecx
    mov     byte [line_has_content], 1
    inc     r15d
    jmp     .fp_word_loop

.fp_end_line:
    cmp     byte [line_has_content], 0
    je      .fp_done
    call    emit_newline

.fp_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; calc_indent_display_width — Returns eax = display width of para indent
; ============================================================================
calc_indent_display_width:
    push    rbx
    xor     eax, eax
    xor     ecx, ecx
    mov     ebx, [para_indent]
.cidw_loop:
    cmp     ecx, ebx
    jge     .cidw_done
    movzx   edx, byte [para_indent_buf + ecx]
    cmp     dl, 9
    jne     .cidw_not_tab
    add     eax, 8
    and     eax, ~7
    jmp     .cidw_next
.cidw_not_tab:
    inc     eax
.cidw_next:
    inc     ecx
    jmp     .cidw_loop
.cidw_done:
    pop     rbx
    ret

; ============================================================================
; emit_indent — Write indent to output
; ============================================================================
emit_indent:
    mov     eax, [para_indent]
    test    eax, eax
    jz      .ei_done
    mov     rdi, para_indent_buf
    mov     edx, eax
    call    emit_bytes
.ei_done:
    ret

; ============================================================================
; emit_newline
; ============================================================================
emit_newline:
    mov     byte [tmp_char], 10
    mov     rdi, tmp_char
    mov     edx, 1
    call    emit_bytes
    ret

; ============================================================================
; emit_bytes — Write edx bytes from rdi to output buffer
; ============================================================================
emit_bytes:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, edx
    mov     r13, [out_pos]

    xor     ecx, ecx
.eb_loop:
    cmp     ecx, r12d
    jge     .eb_done
    movzx   eax, byte [rbx + rcx]
    mov     [out_buf + r13], al
    inc     r13
    inc     ecx
    cmp     r13, FLUSH_THRESHOLD
    jl      .eb_loop
    mov     [out_pos], r13
    push    rcx
    call    flush_output
    pop     rcx
    xor     r13d, r13d
    jmp     .eb_loop

.eb_done:
    mov     [out_pos], r13
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; flush_output
; ============================================================================
flush_output:
    push    rbx
    mov     rbx, [out_pos]
    test    rbx, rbx
    jz      .fo_done
    mov     rdi, STDOUT
    mov     rsi, out_buf
    mov     rdx, rbx
    call    asm_write_all
    mov     qword [out_pos], 0
.fo_done:
    pop     rbx
    ret

; ============================================================================
;  I/O library
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

; ============================================================================
;  Data Section
; ============================================================================

str_prefix:             db "fmt: "
str_prefix_len equ $ - str_prefix

str_newline:            db 10
str_colon_space:        db ": "

str_dashdash_help:      db "--help", 0
str_dashdash_version:   db "--version", 0
str_dashdash_split:     db "--split-only", 0
str_dashdash_uniform:   db "--uniform-spacing", 0
str_dashdash_width:     db "--width", 0
str_dashdash_width_eq:  db "--width=", 0

str_unrecognized:       db "fmt: unrecognized option '", 0
str_unrecognized_len equ $ - str_unrecognized - 1

str_invalid_opt:        db "fmt: invalid option -- '", 0
str_invalid_opt_len equ $ - str_invalid_opt - 1

str_quote_nl:           db "'", 10

str_try_help:           db "Try 'fmt --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_w_requires_arg:     db "option requires an argument -- 'w'"
str_w_requires_arg_len equ $ - str_w_requires_arg

str_width_requires_arg: db "option '--width' requires an argument"
str_width_requires_arg_len equ $ - str_width_requires_arg

str_invalid_width_pre:  db "invalid width: '", 0
str_invalid_width_pre_len equ $ - str_invalid_width_pre - 1

str_invalid_width_suf:  db "'", 10
str_invalid_width_suf_len equ $ - str_invalid_width_suf

str_cannot_open:        db "cannot open '", 0
str_cannot_open_len equ $ - str_cannot_open - 1

str_for_reading:        db "' for reading: No such file or directory", 10
str_for_reading_len equ $ - str_for_reading

; @@DATA_START@@
help_text:
    db "Usage: fmt [-WIDTH] [OPTION]... [FILE]...", 10
    db "Reformat each paragraph in the FILE(s), writing to standard output.", 10
    db "The option -WIDTH is an abbreviated form of --width=DIGITS.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -s, --split-only        split long lines, but do not refill", 10
    db "  -u, --uniform-spacing   one space between words, two after sentences", 10
    db "  -w, --width=WIDTH       maximum line width (default of 75 columns)", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/fmt>", 10
    db "or available locally via: info '(coreutils) fmt invocation'", 10
help_text_len equ $ - help_text

version_text:
    db "fmt (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by Ross Paterson.", 10
version_text_len equ $ - version_text
; @@DATA_END@@

file_end:
