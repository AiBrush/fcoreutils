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
%define goal_width      (width + 4)
%define eff_goal        (goal_width + 4)
%define argc_rem        (eff_goal + 4)
%define flag_split      (argc_rem + 4)
%define flag_uniform    (flag_split + 1)
%define flag_crown      (flag_uniform + 1)
%define flag_prefix     (flag_crown + 1)
%define flag_width_set  (flag_prefix + 1)
%define past_dashdash   (flag_width_set + 1)
%define exit_code       (past_dashdash + 1)
%define opt_char_buf    (exit_code + 1)
%define first_line_para (opt_char_buf + 2)
%define line_has_content (first_line_para + 1)
%define tmp_char        (line_has_content + 1)
%define tmp_char2       (tmp_char + 1)
%define para_indent     (tmp_char2 + 4)
%define cont_indent     (para_indent + 4)
%define crown_first_indent (cont_indent + 4)
%define para_line_num   (crown_first_indent + 4)
%define para_start_pos  (para_line_num + 8)
%define para_single_line_len (para_start_pos + 8)
%define num_files       (para_single_line_len + 8)
%define word_count      (num_files + 4)
%define out_pos         (word_count + 8)
%define prefix_ptr      (out_pos + 8)
%define prefix_len      (prefix_ptr + 8)
%define files           (prefix_len + 4)
%define para_indent_buf (files + MAX_FILES * 8)
%define word_starts     (para_indent_buf + 1024)
%define word_lengths    (word_starts + MAX_WORDS * 8)
%define word_newline_before (word_lengths + MAX_WORDS * 4)
%define word_space_before (word_newline_before + MAX_WORDS)
%define word_cumlen     (word_space_before + MAX_WORDS)
%define dp_cost         (word_cumlen + (MAX_WORDS + 1) * 4)
%define dp_break        (dp_cost + (MAX_WORDS + 1) * 8)
%define dp_line_len     (dp_break + (MAX_WORDS + 1) * 4)
%define input_buf       (dp_line_len + (MAX_WORDS + 1) * 4)
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
    mov     dword [goal_width], 0
    mov     byte [flag_split], 0
    mov     byte [flag_uniform], 0
    mov     byte [flag_crown], 0
    mov     byte [flag_prefix], 0
    mov     byte [flag_width_set], 0
    mov     dword [num_files], 0
    mov     byte [exit_code], 0
    mov     qword [prefix_ptr], 0

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

    ; Check for numeric width: -NNN
    movzx   eax, byte [rsi + 1]
    cmp     al, '0'
    jl      .not_numeric_width
    cmp     al, '9'
    jg      .not_numeric_width
    ; It's -NNN form
    push    rsi
    lea     rsi, [rsi + 1]
    call    parse_number
    test    eax, eax
    js      .numeric_width_bad
    mov     [width], eax
    mov     byte [flag_width_set], 1
    add     rsp, 8
    jmp     .next_arg
.numeric_width_bad:
    pop     rsi
    ; Fall through to short options

.not_numeric_width:
    ; Short options
    mov     rsi, [rbx]
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
    ; If -g was specified without -w, adjust width based on goal
    mov     eax, [goal_width]
    test    eax, eax
    jz      .no_goal_width_adjust
    cmp     byte [flag_width_set], 0
    jne     .no_goal_width_adjust
    ; width = goal + max(10, goal * 7 / 100)
    mov     ecx, eax
    imul    ecx, 7
    xor     edx, edx
    push    rax
    mov     eax, ecx
    mov     ecx, 100
    div     ecx                 ; eax = goal * 7 / 100
    cmp     eax, 10
    jge     .goal_adj_ok
    mov     eax, 10
.goal_adj_ok:
    pop     rcx                 ; ecx = goal
    add     eax, ecx            ; eax = goal + adjustment
    mov     [width], eax
.no_goal_width_adjust:

    ; Compute effective goal width
    ; If user specified -g, use that. Otherwise: goal = width * 187 / 200
    mov     eax, [goal_width]
    test    eax, eax
    jnz     .goal_set
    mov     eax, [width]
    imul    eax, 187
    xor     edx, edx
    mov     ecx, 200
    div     ecx                 ; eax = width * 187 / 200
.goal_set:
    ; Clamp goal to width
    cmp     eax, [width]
    jle     .goal_ok
    mov     eax, [width]
.goal_ok:
    mov     [eff_goal], eax

    ; Compute prefix_len if prefix is set
    mov     dword [prefix_len], 0
    cmp     byte [flag_prefix], 0
    je      .no_prefix_len
    mov     rsi, [prefix_ptr]
    xor     ecx, ecx
.prefix_len_loop:
    cmp     byte [rsi + rcx], 0
    je      .prefix_len_done
    inc     ecx
    jmp     .prefix_len_loop
.prefix_len_done:
    mov     [prefix_len], ecx
.no_prefix_len:

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
    cmp     al, 'c'
    je      .pso_crown
    cmp     al, 't'
    je      .pso_tagged
    cmp     al, 'g'
    je      .pso_goal
    cmp     al, 'p'
    je      .pso_prefix
    jmp     .pso_invalid

.pso_split:
    mov     byte [flag_split], 1
    inc     rsi
    jmp     .pso_loop

.pso_uniform:
    mov     byte [flag_uniform], 1
    inc     rsi
    jmp     .pso_loop

.pso_crown:
    mov     byte [flag_crown], 1
    inc     rsi
    jmp     .pso_loop

.pso_tagged:
    ; -t (tagged paragraph mode) - accept and ignore
    inc     rsi
    jmp     .pso_loop

.pso_goal:
    ; -g takes a numeric argument
    inc     rsi
    movzx   eax, byte [rsi]
    test    al, al
    jz      .pso_goal_next_arg
    cmp     al, '0'
    jl      .pso_goal_next_arg
    cmp     al, '9'
    jg      .pso_goal_next_arg
    push    rsi
    call    parse_number
    test    eax, eax
    js      .pso_goal_invalid_inline
    mov     [goal_width], eax
    add     rsp, 8
    jmp     .pso_loop

.pso_goal_invalid_inline:
    pop     rsi
    jmp     .pso_loop

.pso_goal_next_arg:
    pop     rbx
    add     rbx, 8
    dec     dword [argc_rem]
    cmp     dword [argc_rem], 0
    jle     .pso_goal_missing
    mov     rsi, [rbx]
    push    rsi
    push    rbx
    call    parse_number
    pop     rbx
    test    eax, eax
    js      .pso_goal_bad_nextarg
    mov     [goal_width], eax
    add     rsp, 8
    push    rbx
    jmp     .pso_done

.pso_goal_bad_nextarg:
    pop     rsi
    push    rbx
    jmp     .pso_done

.pso_goal_missing:
    ; Just ignore missing -g arg
    push    rbx
    jmp     .pso_done

.pso_prefix:
    ; -p takes a string argument
    inc     rsi
    movzx   eax, byte [rsi]
    test    al, al
    jz      .pso_prefix_next_arg
    ; Inline argument: -pSTRING
    mov     [prefix_ptr], rsi
    mov     byte [flag_prefix], 1
    ; Skip to end of this arg
.pso_prefix_skip:
    inc     rsi
    cmp     byte [rsi], 0
    jne     .pso_prefix_skip
    jmp     .pso_loop

.pso_prefix_next_arg:
    pop     rbx
    add     rbx, 8
    dec     dword [argc_rem]
    cmp     dword [argc_rem], 0
    jle     .pso_prefix_missing
    mov     rsi, [rbx]
    mov     [prefix_ptr], rsi
    mov     byte [flag_prefix], 1
    push    rbx
    jmp     .pso_done

.pso_prefix_missing:
    push    rbx
    jmp     .pso_done

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
    mov     byte [flag_width_set], 1
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
    mov     byte [flag_width_set], 1
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
    mov     rdi, str_dashdash_crown
    call    strcmp
    test    eax, eax
    jz      .plo_crown

    mov     rsi, [rbx]
    mov     rdi, str_dashdash_tagged
    call    strcmp
    test    eax, eax
    jz      .plo_tagged

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
    mov     rdi, str_dashdash_goal_eq
    mov     ecx, 7
    call    strncmp
    test    eax, eax
    jz      .plo_goal_eq

    mov     rsi, [rbx]
    mov     rdi, str_dashdash_goal
    call    strcmp
    test    eax, eax
    jz      .plo_goal_sep

    mov     rsi, [rbx]
    mov     rdi, str_dashdash_prefix_eq
    mov     ecx, 9
    call    strncmp
    test    eax, eax
    jz      .plo_prefix_eq

    mov     rsi, [rbx]
    mov     rdi, str_dashdash_prefix
    call    strcmp
    test    eax, eax
    jz      .plo_prefix_sep

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

.plo_crown:
    mov     byte [flag_crown], 1
    pop     rbx
    ret

.plo_tagged:
    ; Accept and ignore --tagged-paragraph
    pop     rbx
    ret

.plo_goal_eq:
    mov     rsi, [rbx]
    add     rsi, 7              ; skip "--goal="
    cmp     byte [rsi], 0
    je      .plo_goal_ignore
    push    rsi
    call    parse_number
    test    eax, eax
    js      .plo_goal_ignore_pop
    mov     [goal_width], eax
    add     rsp, 8
    pop     rbx
    ret
.plo_goal_ignore_pop:
    add     rsp, 8
.plo_goal_ignore:
    pop     rbx
    ret

.plo_goal_sep:
    pop     rbx
    add     rbx, 8
    dec     dword [argc_rem]
    cmp     dword [argc_rem], 0
    jle     .plo_goal_sep_done
    mov     rsi, [rbx]
    push    rsi
    push    rbx
    call    parse_number
    pop     rbx
    test    eax, eax
    js      .plo_goal_sep_bad
    mov     [goal_width], eax
    add     rsp, 8
    push    rbx
    pop     rbx
    ret
.plo_goal_sep_bad:
    add     rsp, 8
.plo_goal_sep_done:
    push    rbx
    pop     rbx
    ret

.plo_prefix_eq:
    mov     rsi, [rbx]
    add     rsi, 9              ; skip "--prefix="
    mov     [prefix_ptr], rsi
    mov     byte [flag_prefix], 1
    pop     rbx
    ret

.plo_prefix_sep:
    pop     rbx
    add     rbx, 8
    dec     dword [argc_rem]
    cmp     dword [argc_rem], 0
    jle     .plo_prefix_sep_done
    mov     rsi, [rbx]
    mov     [prefix_ptr], rsi
    mov     byte [flag_prefix], 1
.plo_prefix_sep_done:
    push    rbx
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
    mov     byte [flag_width_set], 1
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
    mov     byte [flag_width_set], 1
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
    ; If prefix mode, check if line starts with prefix
    cmp     byte [flag_prefix], 0
    je      .no_prefix_check
    ; Check prefix match
    mov     rsi, [prefix_ptr]
    mov     ecx, [prefix_len]
    test    ecx, ecx
    jz      .no_prefix_check
    xor     edx, edx
.prefix_check_loop:
    cmp     edx, ecx
    jge     .prefix_matched
    lea     rax, [r13 + rdx]
    cmp     rax, r12
    jge     .prefix_no_match
    movzx   eax, byte [input_buf + r13 + rdx]
    cmp     al, [rsi + rdx]
    jne     .prefix_no_match
    inc     edx
    jmp     .prefix_check_loop
.prefix_no_match:
    ; Line doesn't start with prefix — output verbatim
    mov     rdi, r13
    add     rdi, input_buf
    ; Find end of line
    mov     rdx, r13
.prefix_verbatim_find_eol:
    cmp     rdx, r12
    jge     .prefix_verbatim_emit
    cmp     byte [input_buf + rdx], 10
    je      .prefix_verbatim_emit
    inc     rdx
    jmp     .prefix_verbatim_find_eol
.prefix_verbatim_emit:
    sub     edx, r13d           ; edx = line length
    call    emit_bytes
    call    emit_newline
    ; Advance r13 past line + newline
    mov     rdx, r13
.prefix_verbatim_skip:
    cmp     rdx, r12
    jge     .prefix_verbatim_done
    cmp     byte [input_buf + rdx], 10
    je      .prefix_verbatim_skip_nl
    inc     rdx
    jmp     .prefix_verbatim_skip
.prefix_verbatim_skip_nl:
    inc     rdx                 ; skip the newline
.prefix_verbatim_done:
    mov     r13, rdx
    jmp     .process_loop
.prefix_matched:
    ; Skip past prefix
    add     r13, rcx
.no_prefix_check:
    ; Measure indentation of first line
    call    measure_indent      ; eax = indent byte count
    mov     [para_indent], eax

    ; Save paragraph start position (after prefix)
    mov     [para_start_pos], r13

    ; Collect words from this paragraph
    mov     dword [word_count], 0
    mov     dword [para_line_num], 0
    call    collect_paragraph

    ; Check: if paragraph was a single input line and it fits within goal width,
    ; output the original line verbatim (preserves original spacing).
    ; But NOT if -u flag is set (uniform spacing normalizes everything).
    cmp     byte [flag_uniform], 0
    jne     .do_format
    cmp     dword [para_line_num], 1
    jne     .do_format
    ; Single line: check if original line fits within effective goal
    ; (lines past the goal should be reformatted even if under max width)
    mov     rax, [para_single_line_len]
    cmp     eax, [eff_goal]
    jg      .do_format
    ; Output original line verbatim (with prefix if in prefix mode)
    push    rax
    cmp     byte [flag_prefix], 0
    je      .verbatim_no_prefix
    mov     rdi, [prefix_ptr]
    mov     edx, [prefix_len]
    test    edx, edx
    jz      .verbatim_no_prefix
    call    emit_bytes
.verbatim_no_prefix:
    pop     rax
    mov     rdi, [para_start_pos]
    add     rdi, input_buf
    mov     edx, eax
    call    emit_bytes
    call    emit_newline
    jmp     .process_loop

.do_format:
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
; Tracks line boundaries in word_newline_before[] array
; ============================================================================
collect_paragraph:
    push    rbx
    push    r14
    push    r15

    mov     dword [word_count], 0
    mov     byte [first_line_para], 1
    mov     qword [para_single_line_len], 0

.cp_line_loop:
    cmp     r13, r12
    jge     .cp_done

    cmp     byte [input_buf + r13], 10
    je      .cp_done

    ; If prefix mode: check and strip prefix from continuation lines
    cmp     byte [flag_prefix], 0
    je      .cp_no_prefix_strip
    cmp     byte [first_line_para], 1
    je      .cp_prefix_first_line
    ; Continuation line: check prefix
    mov     rsi, [prefix_ptr]
    mov     ecx, [prefix_len]
    xor     edx, edx
.cp_prefix_check:
    cmp     edx, ecx
    jge     .cp_prefix_strip_ok
    lea     rax, [r13 + rdx]
    cmp     rax, r12
    jge     .cp_done              ; line too short for prefix
    movzx   eax, byte [input_buf + r13 + rdx]
    cmp     al, [rsi + rdx]
    jne     .cp_done              ; prefix mismatch, end paragraph
    inc     edx
    jmp     .cp_prefix_check
.cp_prefix_strip_ok:
    add     r13, rcx              ; skip past prefix
.cp_prefix_first_line:
    ; First line: prefix already stripped by caller
.cp_no_prefix_strip:

    ; For non-first lines: check indentation matches
    cmp     byte [first_line_para], 1
    je      .cp_skip_indent_check

    ; In crown margin mode (-c), accept all non-blank continuation lines
    cmp     byte [flag_crown], 0
    jne     .cp_crown_skip_indent

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
    ; r14b = 1 if this is NOT the first line (i.e. words from this line
    ; came from a joined line, so mark them as "newline before")
    cmp     byte [first_line_para], 1
    je      .cp_first_line
    mov     r14b, 1             ; mark next word as at line boundary
    jmp     .cp_after_first
.cp_first_line:
    mov     r14b, 0             ; first line, no line boundary
.cp_after_first:
    mov     byte [first_line_para], 0

    ; Skip past indentation
    mov     eax, [para_indent]
    add     r13, rax
    jmp     .cp_after_indent_skip

.cp_crown_skip_indent:
    ; In crown mode: skip this line's actual indentation (may differ from para_indent)
    ; Mark as line boundary
    mov     r14b, 1
    mov     byte [first_line_para], 0
    ; Skip whitespace at current position
.cp_crown_skip_ws:
    cmp     r13, r12
    jge     .cp_done
    movzx   eax, byte [input_buf + r13]
    cmp     al, ' '
    je      .cp_crown_skip_ws_next
    cmp     al, 9
    je      .cp_crown_skip_ws_next
    jmp     .cp_after_indent_skip
.cp_crown_skip_ws_next:
    inc     r13
    jmp     .cp_crown_skip_ws

.cp_after_indent_skip:
    ; Count this line
    inc     dword [para_line_num]

    ; r15b tracks: 1 = first word on this input line
    mov     r15b, 1

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

    ; Mark if this word is at a line boundary:
    ; It's at a line boundary if r14b=1 AND r15b=1
    ; (first word on a non-first line of paragraph)
    mov     dl, 0
    test    r14b, r14b
    jz      .cp_no_newline_mark
    test    r15b, r15b
    jz      .cp_no_newline_mark
    mov     dl, 1
.cp_no_newline_mark:
    mov     [word_newline_before + rax], dl
    mov     r15b, 0             ; subsequent words on same line are not first

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
    ; If this is the first line, save its length for single-line verbatim check
    cmp     dword [para_line_num], 1
    jne     .cp_not_first_line_done
    mov     rax, r13
    sub     rax, [para_start_pos]
    mov     [para_single_line_len], rax
.cp_not_first_line_done:
    inc     r13             ; skip newline

    ; In split-only mode, don't join lines
    cmp     byte [flag_split], 0
    jne     .cp_done

    jmp     .cp_line_loop

.cp_done:
    ; If paragraph ended at end of input (no newline), and it's a single line,
    ; save its length
    cmp     dword [para_line_num], 1
    jne     .cp_done_final
    cmp     qword [para_single_line_len], 0
    jne     .cp_done_final
    mov     rax, r13
    sub     rax, [para_start_pos]
    mov     [para_single_line_len], rax
.cp_done_final:
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
; word_ends_sentence — check if word at index r15d ends with sentence punct
; Looks at word_starts[r15d] + word_lengths[r15d] - 1
; Returns: al = 1 if sentence-ending, 0 otherwise
; Preserves: rbx, r12-r15
; ============================================================================
word_ends_sentence:
    push    rbx
    movzx   eax, r15w
    dec     eax                 ; previous word index
    js      .wes_no
    mov     rbx, [word_starts + rax*8]
    mov     ecx, [word_lengths + rax*4]
    test    ecx, ecx
    jz      .wes_no
    ; Look at last char of previous word
    movzx   edx, byte [rbx + rcx - 1]
    ; Check for closing quotes/parens after punctuation
    cmp     dl, '"'
    je      .wes_check_prev
    cmp     dl, 0x27            ; single quote
    je      .wes_check_prev
    cmp     dl, ')'
    je      .wes_check_prev
    cmp     dl, ']'
    je      .wes_check_prev
    ; Direct punctuation check
    cmp     dl, '.'
    je      .wes_yes
    cmp     dl, '?'
    je      .wes_yes
    cmp     dl, '!'
    je      .wes_yes
    jmp     .wes_no

.wes_check_prev:
    ; Char before the closing quote
    cmp     ecx, 2
    jl      .wes_no
    movzx   edx, byte [rbx + rcx - 2]
    cmp     dl, '.'
    je      .wes_yes
    cmp     dl, '?'
    je      .wes_yes
    cmp     dl, '!'
    je      .wes_yes
    jmp     .wes_no

.wes_yes:
    mov     al, 1
    pop     rbx
    ret
.wes_no:
    xor     al, al
    pop     rbx
    ret

; ============================================================================
; format_paragraph — Output words wrapped to [width] using DP optimization
; Uses callee-saved registers throughout
; ============================================================================
format_paragraph:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     eax, [word_count]
    test    eax, eax
    jz      .fp_done

    ; --- Phase 1: Pre-compute space counts and cumulative lengths ---
    ; word_space_before[i]: spaces before word i (0 for i=0, 1 or 2 for i>0)
    mov     byte [word_space_before], 0
    mov     ecx, 1
.fp_precomp_space:
    cmp     ecx, [word_count]
    jge     .fp_precomp_space_done

    ; Default: 1 space
    mov     byte [word_space_before + rcx], 1

    ; Check for double space: at line boundary + sentence ending, or -u + sentence
    ; Check if this word is at a line boundary
    movzx   eax, byte [word_newline_before + rcx]
    test    al, al
    jz      .fp_check_u_space

    ; At line boundary: check previous word for sentence-ending punctuation
    push    rcx
    mov     r15d, ecx           ; word_ends_sentence uses r15
    call    word_ends_sentence
    pop     rcx
    test    al, al
    jz      .fp_check_u_space
    mov     byte [word_space_before + rcx], 2
    jmp     .fp_next_space

.fp_check_u_space:
    cmp     byte [flag_uniform], 0
    je      .fp_next_space
    ; -u mode: check previous word for sentence ending
    push    rcx
    mov     r15d, ecx
    call    word_ends_sentence
    pop     rcx
    test    al, al
    jz      .fp_next_space
    mov     byte [word_space_before + rcx], 2

.fp_next_space:
    inc     ecx
    jmp     .fp_precomp_space
.fp_precomp_space_done:

    ; Build cumulative array: word_cumlen[i] = total display width of words 0..i-1
    ; with their inter-word spaces.
    ; word_cumlen[0] = 0
    ; word_cumlen[i] = word_cumlen[i-1] + word_space_before[i-1] + word_lengths[i-1]
    ; Note: for i=1, space_before[0]=0, so word_cumlen[1] = word_lengths[0]
    mov     dword [word_cumlen], 0
    xor     ecx, ecx            ; ecx = i (from 0)
    xor     edx, edx            ; edx = running total
.fp_build_cum:
    cmp     ecx, [word_count]
    jge     .fp_cum_done
    movzx   eax, byte [word_space_before + rcx]
    add     edx, eax
    add     edx, [word_lengths + rcx*4]
    mov     [word_cumlen + (rcx+1)*4], edx
    inc     ecx
    jmp     .fp_build_cum
.fp_cum_done:

    ; --- Phase 2: DP to find optimal break points ---
    ; indent_width = display width of para_indent
    call    calc_indent_display_width
    mov     ebp, eax            ; ebp = indent_width

    ; text_width = width - indent_width (max text per line)
    mov     r14d, [width]
    sub     r14d, ebp           ; r14d = text_width
    test    r14d, r14d
    jle     .fp_text_width_min
    jmp     .fp_text_width_ok
.fp_text_width_min:
    mov     r14d, 1             ; minimum 1 char per line
.fp_text_width_ok:

    ; text_goal = eff_goal - indent_width
    mov     r13d, [eff_goal]
    sub     r13d, ebp           ; r13d = text_goal
    test    r13d, r13d
    jle     .fp_text_goal_min
    jmp     .fp_text_goal_ok
.fp_text_goal_min:
    mov     r13d, 1
.fp_text_goal_ok:

    mov     r12d, [word_count]  ; r12d = n (word count)

    ; --- Backward DP (like GNU fmt) ---
    ; dp_cost[i] = min cost to format words i..n-1
    ; dp_break[i] = j (last word index of optimal line starting at word i)
    ; dp_line_len[i] = display length of optimal line starting at word i
    ;
    ; dp_cost[n] = 0 (empty suffix, no cost)
    ; For i from n-1 down to 0:
    ;   Try lines i..j for j = i, i+1, ... until line exceeds width
    ;   cost = line_cost(i,j) + LINE_COST + dp_cost[j+1]
    ;   line_cost for last line (j == n-1) = 0
    ;   line_cost otherwise = SHORT_COST(goal - len) + RAGGED_COST

    ; dp_cost[n] = 0
    mov     qword [dp_cost + r12*8], 0
    mov     dword [dp_line_len + r12*4], 0

    ; For i = n-1 down to 0
    lea     r15d, [r12d - 1]    ; r15d = i (outer loop, starts at n-1)

.fp_dp_outer:
    cmp     r15d, 0
    jl      .fp_dp_done

    ; Initialize best_cost to MAX
    mov     rbx, 0x7FFFFFFFFFFFFFFF  ; best_total (in rbx for now, will be stored)
    ; We'll track best_j in [rsp-8] and best_len in [rsp-16] via stack
    ; Actually use BSS-based temp storage to avoid stack complexity
    ; Use register strategy: rbx = best_total, use stack for best_j, best_len

    ; Actually let me use a simpler approach:
    ; Initialize dp_cost[i] to large, then update in inner loop
    mov     dword [dp_cost + r15*8], 0xFF
    mov     dword [dp_cost + r15*8 + 4], 0x7F  ; = 0x7F000000FF = large positive

    ; line_len starts with just word[i] + indent
    ; len = cum[i+1] - cum[i] - space_before[i]  (just word i's length)
    lea     eax, [r15d + 1]
    mov     ecx, [word_cumlen + rax*4]
    sub     ecx, [word_cumlen + r15*4]
    movzx   edx, byte [word_space_before + r15]
    sub     ecx, edx
    ; ecx = length of word[i] alone
    add     ecx, ebp            ; + indent_width = full line display width
    ; But we need text-only width for cost computation
    ; Let's track text_len (without indent) separately
    ; Actually GNU line_cost uses full len including indent. Let me match that.
    ; len = indent + words. Let's just track the full len.

    ; Full line len for just word[i]:
    ; = indent_width + word_lengths[i]
    mov     ecx, ebp            ; indent width
    add     ecx, [word_lengths + r15*4] ; + first word length

    ; ebx will be j (last word in current line attempt)
    mov     ebx, r15d           ; j = i (try 1-word line first)

.fp_dp_inner:
    ; ecx = current line length (indent + words + spaces)
    ; ebx = j (last word index of current line)

    ; Check if line exceeds width
    cmp     ecx, r14d           ; cmp len, text_width... wait
    ; Actually r14d = text_width (width - indent_width)
    ; But our len includes indent_width. Let me use full width.
    mov     eax, [width]
    cmp     ecx, eax
    jge     .fp_dp_too_wide

    ; Line fits. Compute cost.
    ; If j == n-1 (last word): line_cost = 0 (last line of paragraph)
    lea     eax, [r12d - 1]     ; eax = n-1
    cmp     ebx, eax
    je      .fp_dp_last_line_bw

    ; Non-last line: SHORT_COST(goal - len) + RAGGED_COST + LINE_COST
    ; text_len = ecx - ebp (line len minus indent)... wait, goal includes indent?
    ; GNU: goal_width is 93% of max_width, and line lengths include prefix+indent
    ; So compare ecx (full line len) against eff_goal
    mov     eax, [eff_goal]
    sub     eax, ecx            ; goal - len
    imul    eax, 10             ; * 10
    imul    eax, eax            ; squared = SHORT_COST
    movsxd  rax, eax

    ; RAGGED_COST: (len - next_line_len)^2 * 50
    ; Only if the next optimal line is not the last line
    lea     edx, [ebx + 1]     ; next start = j+1
    mov     esi, [dp_break + rdx*4]  ; next_j = dp_break[j+1]
    lea     edi, [r12d - 1]     ; n-1
    cmp     esi, edi
    jge     .fp_dp_no_ragged    ; next line is last line, no ragged cost
    ; next_line_len = dp_line_len[j+1]
    mov     esi, [dp_line_len + rdx*4]
    mov     edx, ecx
    sub     edx, esi            ; len - next_line_len
    imul    edx, edx            ; squared
    imul    edx, 50             ; * 50 = RAGGED_COST
    movsxd  rdx, edx
    add     rax, rdx
.fp_dp_no_ragged:
    add     rax, 4900           ; + LINE_COST
    jmp     .fp_dp_add_cost_bw

.fp_dp_last_line_bw:
    xor     eax, eax
    movsxd  rax, eax            ; line_cost = 0

.fp_dp_add_cost_bw:
    ; total = line_cost + dp_cost[j+1]
    lea     edx, [ebx + 1]
    add     rax, [dp_cost + rdx*8]
    js      .fp_dp_try_next_j   ; overflow, skip

    ; If total < dp_cost[i], update
    cmp     rax, [dp_cost + r15*8]
    jge     .fp_dp_try_next_j

    mov     [dp_cost + r15*8], rax
    mov     [dp_break + r15*4], ebx
    mov     [dp_line_len + r15*4], ecx

.fp_dp_try_next_j:
    ; Try adding one more word to this line
    inc     ebx
    cmp     ebx, r12d
    jge     .fp_dp_next_i       ; no more words

    ; len += space_before[j] + word_lengths[j]
    movzx   eax, byte [word_space_before + rbx]
    add     ecx, eax
    add     ecx, [word_lengths + rbx*4]
    jmp     .fp_dp_inner

.fp_dp_too_wide:
    ; If this is the first word (j == i), accept it anyway (single word)
    cmp     ebx, r15d
    jne     .fp_dp_next_i       ; not first word, stop

    ; Must accept single word even if too wide
    lea     edx, [ebx + 1]
    mov     rax, [dp_cost + rdx*8]
    js      .fp_dp_next_i
    mov     [dp_cost + r15*8], rax
    mov     [dp_break + r15*4], ebx
    mov     [dp_line_len + r15*4], ecx
    jmp     .fp_dp_next_i

.fp_dp_next_i:
    dec     r15d
    jmp     .fp_dp_outer

.fp_dp_done:

    ; --- Phase 3: Trace forward through dp_break[] and emit lines ---
    ; dp_break[i] = j means optimal line starts at word i, ends at word j (inclusive)
    ; Next line starts at j+1.
    ; Follow: i=0 → j=dp_break[0] → i=j+1 → j=dp_break[j+1] → ... until i >= n

    xor     r14d, r14d          ; line counter (0 = first line)
    xor     r15d, r15d          ; r15d = i (current line start word)

.fp_emit_lines:
    cmp     r15d, r12d
    jge     .fp_done

    ; ecx = i (first word of this line)
    mov     ecx, r15d
    ; ebx = j (last word of this line, inclusive) = dp_break[i]
    mov     ebx, [dp_break + r15*4]

    ; ecx = i (first word), ebx = j (last word, inclusive)
    ; Save ecx and ebx on stack (they get clobbered by emit_* calls)
    push    rcx                 ; [rsp+8] = i
    push    rbx                 ; [rsp] = j

    ; Emit prefix if in prefix mode
    cmp     byte [flag_prefix], 0
    je      .fp_no_prefix_emit
    mov     rdi, [prefix_ptr]
    mov     edx, [prefix_len]
    test    edx, edx
    jz      .fp_no_prefix_emit
    call    emit_bytes
.fp_no_prefix_emit:
    ; Emit indent
    call    emit_indent

    ; Restore i and j
    pop     rbx                 ; ebx = j
    pop     rcx                 ; ecx = i

    ; Emit words from i (ecx) to j (ebx), inclusive
    ; Use a local word index in r8d (caller-saved but we don't call anything
    ; between uses — we save/restore around emit_bytes calls)
    mov     r8d, ecx            ; r8d = current word index
    mov     r9d, ecx            ; r9d = first word index (for space check)

.fp_emit_line_words:
    cmp     r8d, ebx
    jg      .fp_emit_line_done  ; past last word (inclusive), done

    ; If not first word on line, emit spaces
    cmp     r8d, r9d
    je      .fp_emit_line_word_only

    ; Emit space(s)
    movzx   edx, byte [word_space_before + r8]
    mov     byte [tmp_char], ' '
    mov     byte [tmp_char2], ' '
    push    r8
    push    r9
    push    rbx
    mov     rdi, tmp_char
    call    emit_bytes
    pop     rbx
    pop     r9
    pop     r8

.fp_emit_line_word_only:
    ; Emit the word
    push    r8
    push    r9
    push    rbx
    mov     rdi, [word_starts + r8*8]
    mov     edx, [word_lengths + r8*4]
    call    emit_bytes
    pop     rbx
    pop     r9
    pop     r8

    inc     r8d
    jmp     .fp_emit_line_words

.fp_emit_line_done:
    ; Emit newline
    push    rbx
    call    emit_newline
    pop     rbx

    ; Advance to next line: r15d = j + 1
    lea     r15d, [ebx + 1]

    inc     r14d                ; next line
    jmp     .fp_emit_lines

.fp_done:
    pop     rbp
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
str_dashdash_crown:     db "--crown-margin", 0
str_dashdash_tagged:    db "--tagged-paragraph", 0
str_dashdash_goal:      db "--goal", 0
str_dashdash_goal_eq:   db "--goal=", 0
str_dashdash_prefix:    db "--prefix", 0
str_dashdash_prefix_eq: db "--prefix=", 0

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
